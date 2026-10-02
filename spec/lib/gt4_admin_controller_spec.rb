# frozen_string_literal: true

require "rails_helper"

RSpec.describe Gt4::AdminController do
  fab!(:admin)
  fab!(:user)

  before do
    SiteSetting.geetest_captcha_enabled = true
    SiteSetting.geetest_captcha_id = "647f5ed2ed8acb4be36784e01556bb71"
    SiteSetting.geetest_captcha_key = "b09a7aafbfd83f73b35a9b530d0337bf"
    Discourse.redis.flushdb
  end

  describe "#status" do
    it "requires an admin" do
      sign_in(user)
      get "/admin/plugins/geetest-captcha/status.json"
      expect(response.status).to eq(404)
    end

    it "returns the configuration summary for an admin" do
      sign_in(admin)
      get "/admin/plugins/geetest-captcha/status.json"

      expect(response.status).to eq(200)
      json = response.parsed_body

      expect(json["enabled"]).to eq(true)
      expect(json["configured"]).to eq(true)
      expect(json["captcha_key_set"]).to eq(true)
      expect(json["scopes"]).to include(
        "signup" => true,
        "login" => false,
        "post" => false,
      )
      expect(json["health"]["ok"]).to eq(true)
    end

    it "never returns the raw captcha_id" do
      sign_in(admin)
      get "/admin/plugins/geetest-captcha/status.json"

      expect(response.parsed_body["captcha_id"]).not_to eq(
        SiteSetting.geetest_captcha_id,
      )
      expect(response.parsed_body["captcha_id"]).to include("…")
    end
  end

  describe "#stats" do
    it "returns the summary and daily breakdown" do
      Gt4::Stats.record("pass")
      Gt4::Stats.record("fail")

      sign_in(admin)
      get "/admin/plugins/geetest-captcha/stats.json", params: { days: 7 }

      expect(response.status).to eq(200)
      json = response.parsed_body

      expect(json["summary"]["pass"]).to eq(1)
      expect(json["summary"]["fail"]).to eq(1)
      expect(json["daily"].length).to eq(7)
    end

    it "clamps out-of-range day windows" do
      sign_in(admin)
      get "/admin/plugins/geetest-captcha/stats.json", params: { days: 500 }

      expect(response.parsed_body["days"]).to eq(7)
    end
  end

  describe "#reset_stats" do
    it "clears the counters" do
      Gt4::Stats.record("pass")

      sign_in(admin)
      delete "/admin/plugins/geetest-captcha/stats.json"

      expect(response.status).to eq(200)
      expect(Gt4::Stats.summary(days: 1)["total"]).to eq(0)
    end
  end

  describe "#toggle" do
    it "flips a scenario switch" do
      sign_in(admin)
      put "/admin/plugins/geetest-captcha/toggle.json", params: { scope: "login", value: true }

      expect(response.status).to eq(200)
      expect(SiteSetting.geetest_captcha_on_login).to eq(true)
    end

    it "rejects an unknown scope" do
      sign_in(admin)
      put "/admin/plugins/geetest-captcha/toggle.json", params: { scope: "nope", value: true }

      expect(response.status).to eq(400)
    end
  end

  describe "#settings" do
    it "requires an admin" do
      sign_in(user)
      get "/admin/plugins/geetest-captcha/settings.json"
      expect(response.status).to eq(404)
    end

    it "returns every setting the plugin owns" do
      sign_in(admin)
      get "/admin/plugins/geetest-captcha/settings.json"

      expect(response.status).to eq(200)
      json = response.parsed_body

      expect(json["settings"].keys).to contain_exactly(
        *Gt4::SettingsRegistry.keys.map(&:to_s),
      )
      expect(json["groups"]).to eq(%w[basic scopes advanced])
      expect(json["health"]).to be_present
    end

    it "never echoes the captcha_id or captcha_key" do
      sign_in(admin)
      get "/admin/plugins/geetest-captcha/settings.json"

      json = response.parsed_body["settings"]

      expect(json["geetest_captcha_id"]["value"]).to eq("")
      expect(json["geetest_captcha_id"]["set"]).to eq(true)
      expect(json["geetest_captcha_id"]["masked"]).to eq(true)

      expect(json["geetest_captcha_key"]["value"]).to eq("")
      expect(json["geetest_captcha_key"]["set"]).to eq(true)
    end

    it "exposes enum choices so the form can render a select" do
      sign_in(admin)
      get "/admin/plugins/geetest-captcha/settings.json"

      product = response.parsed_body["settings"]["geetest_captcha_product"]
      expect(product["type"]).to eq("enum")
      expect(product["choices"]).to eq(%w[bind popup float])
    end
  end

  describe "#save_settings" do
    it "requires an admin" do
      sign_in(user)
      put "/admin/plugins/geetest-captcha/settings.json",
          params: { settings: { geetest_captcha_on_login: true } }
      expect(response.status).to eq(404)
    end

    it "persists multiple settings in one request" do
      sign_in(admin)
      put "/admin/plugins/geetest-captcha/settings.json",
          params: {
            settings: {
              geetest_captcha_language: "eng",
              geetest_captcha_product: "popup",
              geetest_captcha_on_post: true,
            },
          }

      expect(response.status).to eq(200)
      expect(SiteSetting.geetest_captcha_language).to eq("eng")
      expect(SiteSetting.geetest_captcha_product).to eq("popup")
      expect(SiteSetting.geetest_captcha_on_post).to eq(true)
      expect(response.parsed_body["changed"].keys).to contain_exactly(
        "geetest_captcha_language",
        "geetest_captcha_product",
        "geetest_captcha_on_post",
      )
    end

    it "leaves the stored captcha_key untouched when the field is blank" do
      original = SiteSetting.geetest_captcha_key

      sign_in(admin)
      put "/admin/plugins/geetest-captcha/settings.json",
          params: { settings: { geetest_captcha_key: "", geetest_captcha_show_errors: false } }

      expect(response.status).to eq(200)
      expect(SiteSetting.geetest_captcha_key).to eq(original)
      expect(SiteSetting.geetest_captcha_show_errors).to eq(false)
      expect(response.parsed_body["changed"]).not_to have_key("geetest_captcha_key")
    end

    it "reports a no-op save as an empty change set" do
      sign_in(admin)
      put "/admin/plugins/geetest-captcha/settings.json",
          params: { settings: { geetest_captcha_language: SiteSetting.geetest_captcha_language } }

      expect(response.status).to eq(200)
      expect(response.parsed_body["changed"]).to eq({})
    end

    it "rejects an invalid enum without persisting anything" do
      sign_in(admin)
      put "/admin/plugins/geetest-captcha/settings.json",
          params: {
            settings: {
              geetest_captcha_product: "hologram",
              geetest_captcha_language: "jpn",
            },
          }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to have_key("geetest_captcha_product")
      # The *other* valid field in the same request must not be written
      # either: a batch save is all-or-nothing.
      expect(SiteSetting.geetest_captcha_language).not_to eq("jpn")
    end

    it "refuses to enable the plugin without credentials" do
      SiteSetting.geetest_captcha_enabled = false
      SiteSetting.geetest_captcha_id = ""
      SiteSetting.geetest_captcha_key = ""

      sign_in(admin)
      put "/admin/plugins/geetest-captcha/settings.json",
          params: { settings: { geetest_captcha_enabled: true } }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        "geetest_captcha_id",
        "geetest_captcha_key",
      )
      expect(SiteSetting.geetest_captcha_enabled).to eq(false)
    end

    it "allows saving unrelated settings while the plugin is disabled" do
      SiteSetting.geetest_captcha_enabled = false
      SiteSetting.geetest_captcha_id = ""
      SiteSetting.geetest_captcha_key = ""

      sign_in(admin)
      put "/admin/plugins/geetest-captcha/settings.json",
          params: { settings: { geetest_captcha_language: "kor" } }

      expect(response.status).to eq(200)
      expect(SiteSetting.geetest_captcha_language).to eq("kor")
    end

    it "rejects a malformed payload" do
      sign_in(admin)
      put "/admin/plugins/geetest-captcha/settings.json", params: { settings: "nope" }

      expect(response.status).to eq(400)
    end

    it "re-installs the guards when a scope changes" do
      allow(Gt4::Guard).to receive(:install!)

      sign_in(admin)
      put "/admin/plugins/geetest-captcha/settings.json",
          params: { settings: { geetest_captcha_on_post: true } }

      expect(Gt4::Guard).to have_received(:install!)
    end
  end

  describe "#test" do
    it "reports the connectivity result" do
      allow(Gt4::ConnectivityTest).to receive(:run).and_return(
        Gt4::ConnectivityTest::Result.new(
          reachable: true,
          latency_ms: 42,
          detail: "ok",
        ),
      )

      sign_in(admin)
      post "/admin/plugins/geetest-captcha/test.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["result"]).to include(
        "reachable" => true,
        "latency_ms" => 42,
      )
    end
  end
end
