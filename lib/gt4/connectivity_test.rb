# frozen_string_literal: true

module ::Gt4
  # Admin-triggered connectivity probe.
  #
  # Sends a deliberately bogus secondary-validation request to the
  # configured GeeTest endpoint and interprets the reply. Because the
  # payload is invalid, a *reachable* endpoint is expected to answer
  # with a validation failure rather than success — what we are really
  # checking is that DNS, TLS and routing work and that the endpoint
  # accepts our request shape.
  #
  #   200 + {"result":"fail"}                  -> reachable, request parsed
  #   200 + {"status":"error","code":"-50005"} -> reachable, request rejected as malformed
  #   timeout / connection error               -> unreachable
  class ConnectivityTest
    # Deliberately not a real lot_number, so GeeTest can never accept it.
    PROBE_LOT_NUMBER = "0000000000000000000000000000000"

    Result = Struct.new(:reachable, :latency_ms, :detail, :error, keyword_init: true) do
      def reachable?
        !!reachable
      end

      def to_h
        {
          reachable: reachable?,
          latency_ms: latency_ms,
          detail: detail,
          error: error,
        }
      end
    end

    class << self
      def run
        unless SiteSetting.geetest_captcha_id.present? &&
                 SiteSetting.geetest_captcha_key.present?
          return Result.new(
            reachable: false,
            error: "missing_credentials",
            detail: I18n.t("geetest_captcha.admin.test.missing_credentials"),
          )
        end

        client = Client.new(
          captcha_id: SiteSetting.geetest_captcha_id,
          captcha_key: SiteSetting.geetest_captcha_key,
          api_server: SiteSetting.geetest_captcha_api_server,
        )

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response =
          client.validate(
            lot_number: PROBE_LOT_NUMBER,
            captcha_output: "probe",
            pass_token: "probe",
            gen_time: Time.now.to_i.to_s,
          )
        latency = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

        if response[:error]
          Result.new(
            reachable: false,
            latency_ms: latency,
            error: response[:error].to_s,
            detail:
              I18n.t("geetest_captcha.admin.test.unreachable", reason: response[:reason]),
          )
        else
          Result.new(
            reachable: true,
            latency_ms: latency,
            detail: response[:reason].presence || I18n.t("geetest_captcha.admin.test.ok"),
          )
        end
      rescue StandardError => e
        Result.new(reachable: false, error: e.class.name, detail: e.message)
      end
    end
  end
end
