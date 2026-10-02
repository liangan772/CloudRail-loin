# frozen_string_literal: true

# JSON API backing the admin dashboard.
#
# Mounted under /admin/plugins/geetest-captcha/. Every action requires
# an authenticated staff user with admin rights.
#
# IMPORTANT — why this file looks unusual:
#
# The controller subclasses `Admin::AdminController`. If we wrote that
# `class` line at the top level of a file that plugin.rb `require`s
# during boot, any boot where admin controllers are not eager-loaded yet
# (notably `rake db:migrate`) would raise `NameError: uninitialized
# constant Admin::AdminController` and abort the entire bootstrap.
#
# So the class body lives inside `define!`, which is only called once we
# have confirmed the parent constant actually exists.
module ::Gt4
  module AdminControllerDefinition
    class << self
      def parent_available?
        mod = Object
        %w[Admin AdminController].each do |name|
          return false unless mod.is_a?(Module) && mod.const_defined?(name, false)

          mod = mod.const_get(name, false)
        end
        mod.is_a?(Class)
      rescue StandardError
        false
      end

      # Defines Gt4::AdminController. Idempotent.
      def define!
        return false unless parent_available?
        return true if ::Gt4.const_defined?(:AdminController, false)

        ::Gt4.const_set(:AdminController, build_class)
        true
      rescue StandardError => e
        Rails.logger.warn("[geetest-captcha] admin controller not defined: #{e.class}: #{e.message}")
        false
      end

      private

      def build_class
        Class.new(::Admin::AdminController) do
          # ------------------------------------------------------------ #
          #  Read                                                        #
          # ------------------------------------------------------------ #

          # Compact health/status snapshot used by the dashboard header.
          # Kept for backwards compatibility with templates that only
          # need the summary view.
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

          # Every setting the plugin owns, plus the metadata the form
          # needs to render it. Secrets come back as `{ value: "", set: }`
          # so they are never transmitted to the browser.
          def settings
            render json: {
              settings: Gt4::SettingsRegistry.read_all,
              groups: Gt4::SettingsRegistry.groups,
              health: health_report,
            }
          end

          # ------------------------------------------------------------ #
          #  Write                                                       #
          # ------------------------------------------------------------ #

          # Batch save. Accepts `{ settings: { <name>: <value>, ... } }`.
          #
          # All validation happens before anything is persisted, so a
          # partially-invalid form leaves the stored configuration
          # completely untouched.
          def save_settings
            payload = params[:settings]

            unless payload.respond_to?(:to_unsafe_h) || payload.is_a?(Hash)
              return render_json_error(
                       I18n.t("geetest_captcha.admin.errors.invalid_payload"),
                       status: 400,
                       extras: { errors: {} },
                     )
            end

            submitted = payload.respond_to?(:to_unsafe_h) ? payload.to_unsafe_h : payload.to_h
            updates, errors = Gt4::SettingsRegistry.build_updates(submitted)

            if errors.any?
              return render json: {
                              success: false,
                              errors: errors.transform_values { |msgs| msgs.map { |m| error_text(m) } },
                              health: health_report,
                            }, status: 422
            end

            changed = changed_keys(updates)

            begin
              Gt4::SettingsRegistry.apply!(updates)
            rescue StandardError => e
              Rails.logger.warn("[geetest-captcha] save_settings failed: #{e.class}: #{e.message}")
              return render_json_error(
                       I18n.t("geetest_captcha.admin.errors.save_failed"),
                       status: 500,
                       extras: { errors: {} },
                     )
            end

            # A scope toggling on/off means the controller guards have to
            # be re-evaluated against the new configuration.
            Gt4::Guard.install! if (changed.keys & scope_keys).any?

            render json: {
              success: true,
              changed: changed,
              settings: Gt4::SettingsRegistry.read_all,
              health: health_report,
            }
          end

          # ------------------------------------------------------------ #
          #  Diagnostics                                                 #
          # ------------------------------------------------------------ #

          def stats
            days = params[:days].to_i
            days = 7 if days <= 0 || days > 90

            render json: {
              days: days,
              summary: Gt4::Stats.summary(days: days),
              daily: Gt4::Stats.daily(days: days),
            }
          end

          def reset_stats
            Gt4::Stats.reset!
            render json: success_json
          end

          def test
            render json: { result: Gt4::ConnectivityTest.run.to_h }
          end

          # Retained so older bookmarks / third-party scripts keep working.
          # New callers should use `save_settings`.
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
              return render_json_error(
                       I18n.t("geetest_captcha.admin.errors.unknown_scope"),
                       status: 400,
                     )
            end

            SiteSetting.public_send("#{setting_name}=", value)
            Gt4::Guard.install!

            render json: success_json
          end

          private

          def scope_keys
            Gt4::SettingsRegistry.for_group(:scopes).map { |d| d[:key] } +
              [:geetest_captcha_enabled]
          end

          # Only report settings whose value actually moved, so the UI can
          # say "nothing changed" instead of pretending it saved.
          def changed_keys(updates)
            updates.each_with_object({}) do |(key, value), acc|
              before = SiteSetting.public_send(key)
              acc[key] = value unless before.to_s == value.to_s
            end
          end

          def error_text(message)
            key = "geetest_captcha.admin.errors.#{message}"
            text = I18n.t(key)
            text.to_s.start_with?("translation missing") ? message.to_s : text
          end

          def configured?
            SiteSetting.geetest_captcha_id.present? &&
              SiteSetting.geetest_captcha_key.present?
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
              SiteSetting.geetest_captcha_on_signup ||
                SiteSetting.geetest_captcha_on_login ||
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
    end
  end
end
