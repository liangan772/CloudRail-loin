# frozen_string_literal: true

require "rails_helper"
require "openssl"

RSpec.describe Gt4::Client do
  subject(:client) do
    described_class.new(
      captcha_id: "647f5ed2ed8acb4be36784e01556bb71",
      captcha_key: "b09a7aafbfd83f73b35a9b530d0337bf",
      api_server: "gcaptcha4.geetest.com",
    )
  end

  describe "#sign" do
    it "matches the GT4 HMAC-SHA256 signature of the lot_number" do
      lot_number = "4dc3cfc2cdff448cad8d13107198d473"
      expected =
        OpenSSL::HMAC.hexdigest("SHA256", "b09a7aafbfd83f73b35a9b530d0337bf", lot_number)

      expect(client.sign(lot_number)).to eq(expected)
    end

    it "produces a 64 character lowercase hex digest" do
      expect(client.sign("abc")).to match(/\A[0-9a-f]{64}\z/)
    end
  end

  describe "#validate" do
    let(:payload) do
      {
        lot_number: "4dc3cfc2cdff448cad8d13107198d473",
        captcha_output: "output",
        pass_token: "token",
        gen_time: "1700000000",
      }
    end

    def stub_validate(body, code: "200")
      response = instance_double(Net::HTTPResponse, body: body, code: code)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(code == "200")
      allow_any_instance_of(Net::HTTP).to receive(:request).and_return(response)
    end

    it "returns ok when GeeTest reports success" do
      stub_validate(
        '{"status":"success","result":"success","reason":"","captcha_args":{"used_type":"slide"}}',
      )

      result = client.validate(**payload)

      expect(result[:ok]).to be(true)
      expect(result[:result]).to eq("success")
    end

    it "returns not-ok when GeeTest reports failure" do
      stub_validate('{"status":"success","result":"fail","reason":"pass_token expire"}')

      result = client.validate(**payload)

      expect(result[:ok]).to be(false)
      expect(result[:reason]).to eq("pass_token expire")
    end

    it "maps a transport-level error payload to :request_failed" do
      stub_validate('{"status":"error","code":"-50005","msg":"illegal gen_time"}')

      result = client.validate(**payload)

      expect(result[:ok]).to be(false)
      expect(result[:error]).to eq(:request_failed)
    end

    it "maps a non-200 HTTP response to :request_failed" do
      stub_validate("boom", code: "500")

      result = client.validate(**payload)

      expect(result[:error]).to eq(:request_failed)
    end

    it "maps a timeout to :timeout instead of raising" do
      allow_any_instance_of(Net::HTTP).to receive(:request).and_raise(Net::ReadTimeout)

      expect(client.validate(**payload)[:error]).to eq(:timeout)
    end

    it "maps malformed JSON to :request_failed" do
      stub_validate("<html>not json</html>")

      expect(client.validate(**payload)[:error]).to eq(:request_failed)
    end
  end
end
