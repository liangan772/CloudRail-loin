# frozen_string_literal: true

require "openssl"
require "net/http"
require "uri"
require "json"

module ::Gt4
  # Low level HTTP client for the GeeTest CAPTCHA v4 secondary
  # validation endpoint.
  #
  # Docs: https://docs.geetest.com/gt4/deploy/server
  #
  #   POST http://gcaptcha4.geetest.com/validate?captcha_id=<id>
  #   Content-Type: application/x-www-form-urlencoded
  #
  #   lot_number, captcha_output, pass_token, gen_time, sign_token
  class Client
    DEFAULT_API_SERVER = "gcaptcha4.geetest.com"
    VALIDATE_PATH = "/validate"
    DEFAULT_TIMEOUT = 5 # seconds

    def initialize(
      captcha_id:,
      captcha_key:,
      api_server: DEFAULT_API_SERVER,
      timeout: DEFAULT_TIMEOUT
    )
      @captcha_id = captcha_id.to_s
      @captcha_key = captcha_key.to_s
      @api_server = normalize_server(api_server)
      @timeout = timeout
    end

    # Builds the HMAC-SHA256 signature required by GT4.
    #
    #   message = lot_number
    #   key     = captcha_key
    #   sign_token = HMAC-SHA256(key, message).hexdigest
    def sign(lot_number)
      OpenSSL::HMAC.hexdigest("SHA256", @captcha_key, lot_number.to_s)
    end

    # Performs the secondary validation.
    #
    # Returns a Hash:
    #   { ok: true,  result: "success", reason: "", captcha_args: {...} }
    #   { ok: false, result: "fail",    reason: "...", captcha_args: {...} }
    #   { ok: false, error: :request_failed, reason: "..." }
    def validate(lot_number:, captcha_output:, pass_token:, gen_time:)
      payload = {
        "lot_number" => lot_number.to_s,
        "captcha_output" => captcha_output.to_s,
        "pass_token" => pass_token.to_s,
        "gen_time" => gen_time.to_s,
        "sign_token" => sign(lot_number),
      }

      uri = URI.parse("https://#{@api_server}#{VALIDATE_PATH}")
      uri.query = URI.encode_www_form("captcha_id" => @captcha_id)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @timeout
      http.read_timeout = @timeout

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = URI.encode_www_form(payload)

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        return {
          ok: false,
          error: :request_failed,
          reason: "http #{response.code}",
        }
      end

      parsed = JSON.parse(response.body)

      # GT4 returns a distinct shape for transport-level errors:
      #   { "status": "error", "code": "-50005", "msg": "..." }
      if parsed["status"] == "error"
        return {
          ok: false,
          error: :request_failed,
          reason: "#{parsed["code"]} #{parsed["msg"]}",
        }
      end

      passed = parsed["result"] == "success"
      {
        ok: passed,
        result: parsed["result"],
        reason: parsed["reason"].to_s,
        captcha_args: parsed["captcha_args"] || {},
      }
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
      { ok: false, error: :timeout, reason: e.class.name }
    rescue JSON::ParserError => e
      { ok: false, error: :request_failed, reason: "invalid json: #{e.message}" }
    rescue StandardError => e
      { ok: false, error: :request_failed, reason: "#{e.class}: #{e.message}" }
    end

    private

    def normalize_server(server)
      server = server.to_s.strip
      server = DEFAULT_API_SERVER if server.empty?
      server.sub(%r{\Ahttps?://}, "").sub(%r{/\z}, "")
    end
  end
end
