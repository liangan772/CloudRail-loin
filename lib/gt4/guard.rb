# frozen_string_literal: true

module ::Gt4
  # Wires `Gt4::Validator` into the concrete Discourse endpoints.
  #
  # Every controller reference is resolved lazily and defensively: during
  # a `rake db:migrate` boot the controllers may not be loaded yet, and a
  # bare `::SignupController` reference would raise `NameError` and abort
  # the whole bootstrap. `resolve` returns nil instead, and the guard is
  # simply not installed for that endpoint.
  module Guard
    module SignupGuard
      def create
        return unless verify_geetest!(scope: :signup)

        super
      end
    end

    module SessionGuard
      def create
        return unless verify_geetest!(scope: :login)

        super
      end
    end

    module PostGuard
      def create
        # Only guard human-initiated posts. System / bot posts (imports,
        # mail-in replies, scheduled jobs) never carry a GT4 payload, so
        # guarding them would break core behaviour.
        if current_user && !current_user.bot?
          return unless verify_geetest!(scope: :post)
        end

        super
      end
    end

    # scope => [controller constant path, site setting, guard module]
    #
    # Defined after the guard modules above: a constant whose value
    # references other constants must be declared last.
    CONTROLLERS = {
      signup: ["::SignupController", :geetest_captcha_on_signup, SignupGuard],
      login: ["::SessionController", :geetest_captcha_on_login, SessionGuard],
      post: ["::PostsController", :geetest_captcha_on_post, PostGuard],
    }.freeze

    class << self
      # Idempotent. Safe to call at boot and again on every site-setting
      # change.
      def install!
        CONTROLLERS.each do |_scope, (const_path, setting, mod)|
          next unless scope_enabled?(setting)

          klass = resolve(const_path)
          next unless klass

          prepend_once(klass, mod)
        end
      rescue StandardError => e
        Rails.logger.warn("[geetest-captcha] guard install failed: #{e.class}: #{e.message}")
      end

      private

      def scope_enabled?(setting)
        SiteSetting.respond_to?(setting) && SiteSetting.public_send(setting)
      rescue StandardError
        false
      end

      # Resolves a namespaced constant, returning nil instead of raising
      # when any segment is missing.
      def resolve(path)
        path.split("::").reject(&:empty?).reduce(Object) do |mod, name|
          return nil unless mod.is_a?(Module) && mod.const_defined?(name, false)

          mod.const_get(name, false)
        end
      rescue StandardError
        nil
      end

      def prepend_once(klass, mod)
        return if klass.ancestors.include?(mod)

        klass.prepend(mod)
      end
    end
  end
end
