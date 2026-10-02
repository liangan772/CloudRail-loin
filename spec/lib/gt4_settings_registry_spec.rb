# frozen_string_literal: true

require "rails_helper"

RSpec.describe Gt4::SettingsRegistry do
  describe ".keys" do
    it "matches the settings declared in config/settings.yml" do
      declared =
        YAML
          .unsafe_load_file(Rails.root.join("plugins", "discourse-geetest-captcha", "config", "settings.yml"))
          .fetch("plugins")
          .keys
          .map(&:to_sym)

      # The registry is the single source of truth *for behaviour*; this
      # assertion keeps it honest about *coverage*.
      expect(described_class.keys).to contain_exactly(*declared)
    end

    it "assigns every setting to a known group" do
      described_class.all.each do |definition|
        expect(described_class.groups).to include(definition[:group])
      end
    end
  end

  describe ".read_all" do
    before do
      SiteSetting.geetest_captcha_id = "647f5ed2ed8acb4be36784e01556bb71"
      SiteSetting.geetest_captcha_key = "b09a7aafbfd83f73b35a9b530d0337bf"
    end

    it "returns a fingerprint instead of the raw value for masked settings" do
      entry = described_class.read_all[:geetest_captcha_id]

      expect(entry[:value]).to eq("")
      expect(entry[:set]).to eq(true)
      expect(entry[:masked]).to eq(true)
      expect(entry[:fingerprint]).to eq("647f…bb71")
    end

    it "returns plain values verbatim" do
      entry = described_class.read_all[:geetest_captcha_api_server]

      expect(entry[:value]).to eq("gcaptcha4.geetest.com")
      expect(entry[:masked]).to eq(false)
    end

    it "carries the metadata the form needs" do
      entry = described_class.read_all[:geetest_captcha_product]

      expect(entry[:type]).to eq(:enum)
      expect(entry[:group]).to eq(:basic)
      expect(entry[:choices]).to eq(%w[bind popup float])
    end
  end

  describe ".build_updates" do
    it "coerces booleans from strings" do
      updates, errors = described_class.build_updates(
        geetest_captcha_on_login: "true",
        geetest_captcha_on_post: "false",
      )

      expect(errors).to be_empty
      expect(updates[:geetest_captcha_on_login]).to eq(true)
      expect(updates[:geetest_captcha_on_post]).to eq(false)
    end

    it "accepts a valid enum choice" do
      updates, errors = described_class.build_updates(geetest_captcha_product: "float")

      expect(errors).to be_empty
      expect(updates[:geetest_captcha_product]).to eq("float")
    end

    it "rejects an unknown enum choice" do
      updates, errors = described_class.build_updates(geetest_captcha_product: "hologram")

      expect(updates).not_to have_key(:geetest_captcha_product)
      expect(errors[:geetest_captcha_product]).to eq([:invalid_choice])
    end

    it "skips a blank secret instead of clearing it" do
      updates, errors = described_class.build_updates(geetest_captcha_key: "")

      expect(updates).not_to have_key(:geetest_captcha_key)
      expect(errors).to be_empty
    end

    it "trims surrounding whitespace" do
      updates, = described_class.build_updates(geetest_captcha_id: "  abcdef0123456789  ")

      expect(updates[:geetest_captcha_id]).to eq("abcdef0123456789")
    end

    it "rejects a value that does not match the field pattern" do
      updates, errors = described_class.build_updates(geetest_captcha_id: "not a valid id!")

      expect(updates).not_to have_key(:geetest_captcha_id)
      expect(errors[:geetest_captcha_id]).to eq([:invalid_format])
    end

    it "rejects a full URL for the api server host" do
      _updates, errors =
        described_class.build_updates(
          geetest_captcha_api_server: "https://gcaptcha4.geetest.com",
        )

      expect(errors[:geetest_captcha_api_server]).to eq([:invalid_format])
    end

    it "ignores keys that are not part of the registry" do
      updates, errors = described_class.build_updates(rails_env: "production")

      expect(updates).to be_empty
      expect(errors).to be_empty
    end

    context "when enabling the plugin" do
      before do
        SiteSetting.geetest_captcha_id = ""
        SiteSetting.geetest_captcha_key = ""
      end

      it "requires credentials" do
        _updates, errors = described_class.build_updates(geetest_captcha_enabled: true)

        expect(errors).to include(:geetest_captcha_id, :geetest_captcha_key)
      end

      it "accepts credentials supplied in the same request" do
        _updates, errors =
          described_class.build_updates(
            geetest_captcha_enabled: true,
            geetest_captcha_id: "abcdef0123456789",
            geetest_captcha_key: "0123456789abcdef",
          )

        expect(errors).to be_empty
      end

      it "accepts already-stored credentials" do
        SiteSetting.geetest_captcha_id = "abcdef0123456789"
        SiteSetting.geetest_captcha_key = "0123456789abcdef"

        _updates, errors = described_class.build_updates(geetest_captcha_enabled: true)

        expect(errors).to be_empty
      end
    end

    context "when the plugin stays disabled" do
      it "does not demand credentials" do
        SiteSetting.geetest_captcha_id = ""
        SiteSetting.geetest_captcha_key = ""

        _updates, errors = described_class.build_updates(geetest_captcha_enabled: false)

        expect(errors).to be_empty
      end
    end
  end

  describe ".apply!" do
    it "writes each value to the matching site setting" do
      described_class.apply!(
        geetest_captcha_product: "popup",
        geetest_captcha_on_post: true,
      )

      expect(SiteSetting.geetest_captcha_product).to eq("popup")
      expect(SiteSetting.geetest_captcha_on_post).to eq(true)
    end
  end
end
