# frozen_string_literal: true

module ::Gt4
  # Orchestrates the server-side half of GeeTest CAPTCHA v4.
  #
  # Usage from a controller:
  #
  #   result = Gt4::Validator.verify!(params, scope: :signup)
  #   return render_json_error(...) unless result.ok?
  #
  # The validator is deliberately fail-open by default: if the GeeTest
  # service is unreachable, normal users must not be locked out. This
  # mirrors the guidance in the official deployment docs ("处理容灾降级
  # 逻辑") and is controlled by the `geetest_captcha_fail_open` setting.
  class Validator
    PARAM_KEYS = %w[lot_number captcha_output pass_token gen_time].freeze

    Result = Struct.new(:ok, :reason, :error, :captcha_args, keyword_init: true) do
      def ok?
        !!ok
      end
    end

    class << self
      # Returns true when verification is enforced for the given scope.
      def enabled_for?(scope)
        return false unless SiteSetting.geetest_captcha_enabled
        return false if SiteSetting.geetest_captcha_id.blank?
        return false if SiteSetting.geetest_captcha_key.blank?

        case scope.to_sym
        when :signup then SiteSetting.geetest_captcha_on_signup
        when :login then SiteSetting.geetest_captcha_on_login
        when :post then SiteSetting.geetest_captcha_on_post
        else false
        end
      end

      # Verifies the GT4 payload carried by `params`.
      #
      # `scope` is one of :signup, :login, :post. When verification is
      # not enabled for that scope this returns an ok result so callers
      # can use it unconditionally.
      def verify(params, scope:)
        return Result.new(ok: true, reason: "verification disabled") unless enabled_for?(scope)

        extracted = extract(params)

        if extracted.values.any?(&:blank?)
          return Result.new(ok: false, error: :missing_params, reason: "missing params")
        end

        # Reject an already-consumed challenge before spending a network
        # round trip on it.
        unless VerifiedStore.claim(extracted["lot_number"])
          return Result.new(ok: false, error: :already_used, reason: "lot_number already used")
        end

        response = client.validate(
          lot_number: extracted["lot_number"],
          captcha_output: extracted["captcha_output"],
          pass_token: extracted["pass_token"],
          gen_time: extracted["gen_time"],
        )

        if response[:error]
          # Transport failure. Hand the lot_number back so a genuine
          # retry is still possible, then apply the fail-open policy.
          VerifiedStore.release(extracted["lot_number"])

          return Result.new(
            ok: SiteSetting.geetest_captcha_fail_open,
            error: response[:error],
            reason: response[:reason],
          )
        end

        unless response[:ok]
          VerifiedStore.release(extracted["lot_number"])
          return Result.new(
            ok: false,
            error: :validate_failed,
            reason: response[:reason],
            captcha_args: response[:captcha_args],
          )
        end

        Result.new(ok: true, reason: "", captcha_args: response[:captcha_args])
      end

      # Emits a Discourse-compatible error JSON blob for a failed result.
      def error_message(result)
        key =
          case result.error
          when :missing_params then "missing_params"
          when :already_used then "already_used"
          when :request_failed then "request_failed"
          when :timeout then "request_failed"
          when :validate_failed then "validate_failed"
          else "validate_failed"
          end

        message = I18n.t("geetest_captcha.errors.#{key}")
        # Only surface GeeTest's own reason text when the admin opted in.
        if SiteSetting.geetest_captcha_show_errors && result.reason.present?
          "#{message} (#{result.reason})"
        else
          message
        end
      end

      private

      def extract(params)
        PARAM_KEYS.each_with_object({}) do |key, memo|
          memo[key] = params[key].to_s.strip
        end
      end

      def client
        Client.new(
          captcha_id: SiteSetting.geetest_captcha_id,
          captcha_key: SiteSetting.geetest_captcha_key,
          api_server: SiteSetting.geetest_captcha_api_server,
        )
      end
    end
  end
end
