# frozen_string_literal: true

require "rails_helper"

RSpec.describe Gt4::Validator do
  fab!(:user)

  let(:valid_params) do
    {
      "lot_number" => "4dc3cfc2cdff448cad8d13107198d473",
      "captcha_output" => "output",
      "pass_token" => "token",
      "gen_time" => "1700000000",
    }
  end

  before do
    SiteSetting.geetest_captcha_enabled = true
    SiteSetting.geetest_captcha_id = "647f5ed2ed8acb4be36784e01556bb71"
    SiteSetting.geetest_captcha_key = "b09a7aafbfd83f73b35a9b530d0337bf"
    SiteSetting.geetest_captcha_on_signup = true
    SiteSetting.geetest_captcha_fail_open = true
    Discourse.redis.flushdb
  end

  describe ".enabled_for?" do
    it "returns true for an enabled scope" do
      expect(described_class.enabled_for?(:signup)).to be(true)
    end

    it "returns false for a scope that is switched off" do
      SiteSetting.geetest_captcha_on_login = false
      expect(described_class.enabled_for?(:login)).to be(false)
    end

    it "returns false when credentials are missing" do
      SiteSetting.geetest_captcha_id = ""
      expect(described_class.enabled_for?(:signup)).to be(false)
    end
  end

  describe ".verify" do
    it "reports missing params for an incomplete payload" do
      result = described_class.verify({ "lot_number" => "x" }, scope: :signup)

      expect(result.ok?).to be(false)
      expect(result.error).to eq(:missing_params)
    end

    it "passes through when the scope is disabled" do
      SiteSetting.geetest_captcha_on_signup = false

      expect(described_class.verify({}, scope: :signup).ok?).to be(true)
    end

    it "accepts a valid challenge" do
      allow_any_instance_of(Gt4::Client).to receive(:validate).and_return(
        { ok: true, result: "success", reason: "" },
      )

      expect(described_class.verify(valid_params, scope: :signup).ok?).to be(true)
    end

    it "rejects a replayed lot_number" do
      allow_any_instance_of(Gt4::Client).to receive(:validate).and_return(
        { ok: true, result: "success", reason: "" },
      )

      expect(described_class.verify(valid_params, scope: :signup).ok?).to be(true)

      second = described_class.verify(valid_params, scope: :signup)
      expect(second.ok?).to be(false)
      expect(second.error).to eq(:already_used)
    end

    it "releases the lot_number so a failed business retry can reuse it" do
      allow_any_instance_of(Gt4::Client).to receive(:validate).and_return(
        { ok: false, error: :validate_failed, reason: "fail" },
      )

      described_class.verify(valid_params, scope: :signup)

      # After a failed validation the lot is released, so it is not
      # permanently burned.
      expect(Gt4::VerifiedStore.claimed?(valid_params["lot_number"])).to be(false)
    end

    it "fails open on a transport error when fail_open is on" do
      allow_any_instance_of(Gt4::Client).to receive(:validate).and_return(
        { ok: false, error: :timeout, reason: "Net::ReadTimeout" },
      )

      expect(described_class.verify(valid_params, scope: :signup).ok?).to be(true)
    end

    it "fails closed on a transport error when fail_open is off" do
      SiteSetting.geetest_captcha_fail_open = false
      allow_any_instance_of(Gt4::Client).to receive(:validate).and_return(
        { ok: false, error: :timeout, reason: "Net::ReadTimeout" },
      )

      expect(described_class.verify(valid_params, scope: :signup).ok?).to be(false)
    end
  end
end
