# frozen_string_literal: true

module ::Gt4
  # Adds the four GeeTest fields to Discourse's strong parameters and
  # provides `verify_geetest!` for controllers.
  #
  # Discourse (3.x+) exposes `Discourse::ApplicationController.permitted`
  # which accepts a `:params` block describing additional permitted keys.
  # If that API is unavailable we fall back to a direct `permit` patch,
  # so the plugin still works on older 3.2/3.3 installs.
  module ControllerExtension
    GT4_FIELDS = %i[lot_number captcha_output pass_token gen_time].freeze

    def self.included(base)
      base.helper_method(:geetest_enabled_for?) if base.respond_to?(:helper_method)
    end

    # Registers the GT4 fields as permitted for a given controller key.
    def self.permit_gt4_params(controller_key)
      if Discourse::ApplicationController.respond_to?(:permitted)
        Discourse::ApplicationController.permitted(controller_key, :params) do
          params.permit(*GT4_FIELDS)
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[geetest-captcha] failed to register permitted params for " \
                        "#{controller_key}: #{e.message}")
    end

    # Controller-level guard.
    #
    #   verify_geetest!(scope: :signup)
    #
    # Returns true when the request may proceed. When verification
    # fails the response is rendered here and the return value is false,
    # so callers should `return unless verify_geetest!(...)`.
    def verify_geetest!(scope:)
      return true unless Gt4::Validator.enabled_for?(scope)

      result = Gt4::Validator.verify(params, scope: scope)
      return true if result.ok?

      render_json_error(Gt4::Validator.error_message(result), status: 403)
      false
    end

    def geetest_enabled_for?(scope)
      Gt4::Validator.enabled_for?(scope)
    end

    # Releases a claimed challenge so the user can retry after a
    # business-level failure (e.g. wrong password).
    def release_geetest!
      Gt4::VerifiedStore.release(params[:lot_number].to_s)
    end
  end
end
