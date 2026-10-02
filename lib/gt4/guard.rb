# frozen_string_literal: true

module ::Gt4
  # Wires `Gt4::Validator` into the concrete Discourse endpoints.
  #
  # Signup, login and post creation all run through `before_action`
  # style prepends on their controllers. A failed verification renders
  # a 403 JSON error and short-circuits, so no account/post work ever
  # happens for an unverified request.
  module Guard
    class << self
      def install!
        prepend_once(::SignupController, SignupGuard) if SiteSetting.geetest_captcha_on_signup
        prepend_once(::SessionController, SessionGuard) if SiteSetting.geetest_captcha_on_login
        prepend_once(::PostsController, PostGuard) if SiteSetting.geetest_captcha_on_post
      end

      private

      def prepend_once(klass, mod)
        return if klass.ancestors.include?(mod)

        klass.prepend(mod)
      end
    end

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
  end
end
