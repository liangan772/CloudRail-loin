# frozen_string_literal: true

module ::Gt4
  # JSON API backing the admin dashboard.
  #
  # Mounted under /admin/plugins/geetest-captcha/. Every action requires
  # an authenticated staff user with admin rights.
  class AdminController < ::Admin::AdminController
    def status
      render json: {
        enabled: SiteSetting.geetest_captcha_enabled,
        configured: configured?,
        captcha_id: masked_captcha_id,
        captcha_key_set: SiteSetting.geetest_captcha_key.present?,
        api_server: SiteSetting.geetest_captcha_api_server,
        product: SiteSetting.geetest_captcha_product,
        language: SiteSetting.geetest_captcha_language,
        fail_open: SiteSetting.geetest_captcha_fail_open,
        show_errors: SiteSetting.geetest_captcha_show_errors,
        scopes: {
          signup: SiteSetting.geetest_captcha_on_signup,
          login: SiteSetting.geetest_captcha_on_login,
          post: SiteSetting.geetest_captcha_on_post,
        },
        health: health_report,
      }
    end

    def stats
      days = params[:days].to_i
      days = 7 if days <= 0 || days > 90

      render json: {
        days: days,
        summary: Stats.summary(days: days),
        daily: Stats.daily(days: days),
      }
    end

    def reset_stats
      Stats.reset!
      render json: success_json
    end

    def test
      render json: { result: ConnectivityTest.run.to_h }
    end

    def toggle
      scope = params[:scope].to_s
      value = ActiveModel::Type::Boolean.new.cast(params[:value])

      setting_name =
        case scope
        when "signup" then :geetest_captcha_on_signup
        when "login" then :geetest_captcha_on_login
        when "post" then :geetest_captcha_on_post
        when "enabled" then :geetest_captcha_enabled
        end

      if setting_name.nil?
        return render_json_error(I18n.t("geetest_captcha.admin.errors.unknown_scope"), status: 400)
      end

      SiteSetting.public_send("#{setting_name}=", value)
      Gt4::Guard.install!

      render json: success_json
    end

    private

    def configured?
      SiteSetting.geetest_captcha_id.present? && SiteSetting.geetest_captcha_key.present?
    end

    # Never echo a full captcha_id back to the browser; show a short
    # fingerprint so admins can confirm *which* id is deployed.
    def masked_captcha_id
      id = SiteSetting.geetest_captcha_id.to_s
      return "" if id.empty?
      return "#{id[0, 4]}…" if id.length <= 8

      "#{id[0, 4]}…#{id[-4, 4]}"
    end

    def health_report
      checks = []

      checks << {
        key: "enabled",
        ok: SiteSetting.geetest_captcha_enabled,
        label: I18n.t("geetest_captcha.admin.checks.enabled"),
      }

      checks << {
        key: "captcha_id",
        ok: SiteSetting.geetest_captcha_id.present?,
        label: I18n.t("geetest_captcha.admin.checks.captcha_id"),
      }

      checks << {
        key: "captcha_key",
        ok: SiteSetting.geetest_captcha_key.present?,
        label: I18n.t("geetest_captcha.admin.checks.captcha_key"),
      }

      any_scope =
        SiteSetting.geetest_captcha_on_signup || SiteSetting.geetest_captcha_on_login ||
          SiteSetting.geetest_captcha_on_post

      checks << {
        key: "scope",
        ok: any_scope,
        label: I18n.t("geetest_captcha.admin.checks.scope"),
      }

      { ok: checks.all? { |c| c[:ok] }, checks: checks }
    end
  end
end
