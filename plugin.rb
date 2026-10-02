# frozen_string_literal: true

# name: discourse-geetest-captcha
# about: GeeTest CAPTCHA v4 (极验行为验证第四代) human verification for Discourse
# version: 1.2.0
# authors: liangan772
# url: https://github.com/liangan772/CloudRail-loin
# required_version: 3.2.0

enabled_site_setting :geetest_captcha_enabled

register_asset "stylesheets/common/geetest-captcha.scss"
register_asset "stylesheets/admin/geetest-captcha-admin.scss"

add_admin_route "geetest_captcha.admin.nav_label", "geetest-captcha"

# --------------------------------------------------------------------- #
#  IMPORTANT: nothing in this file may touch application constants at   #
#  load time. `rake db:migrate` (and any other rake task) boots the     #
#  Rails environment, and eager-loading controllers that may not exist  #
#  yet will hard-fail the bootstrap. All wiring is therefore deferred   #
#  to `after_initialize` + `on(:web_only_initializer)` style hooks and  #
#  is wrapped in defensive guards.                                      #
# --------------------------------------------------------------------- #

after_initialize do
  # Autoload `lib/` under the `Gt4` namespace.
  #
  # `Rails.autoloaders.main.push_dir` must run *during* boot, and it
  # raises if the loader has already been set up and the directory was
  # not registered up-front. We guard it so a rake task can never be
  # broken by it.
  begin
    lib_dir = File.expand_path("lib", __dir__)
    unless Rails.autoloaders.main.dirs.include?(lib_dir)
      Rails.autoloaders.main.push_dir(lib_dir, namespace: Gt4)
    end
  rescue StandardError => e
    Rails.logger.warn("[geetest-captcha] autoload setup skipped: #{e.message}")
  end

  require_relative "lib/gt4/client"
  require_relative "lib/gt4/verified_store"
  require_relative "lib/gt4/stats"
  require_relative "lib/gt4/validator"
  require_relative "lib/gt4/connectivity_test"
  require_relative "lib/gt4/controller_extension"
  require_relative "lib/gt4/guard"
  require_relative "lib/gt4/admin_controller"

  # Whitelist the GT4 fields, then install the guards.
  #
  # Both operations are wrapped internally so a missing controller (for
  # example during a partial boot) degrades to a warning instead of
  # aborting the whole process.
  Gt4::ControllerExtension.install!

  # The admin controller subclasses `Admin::AdminController`, which is not
  # guaranteed to be loaded during every boot. `define!` checks for the
  # parent constant first and no-ops when it is absent, so this can never
  # break `rake db:migrate`.
  Gt4::AdminControllerDefinition.define!

  on(:site_setting_changed) do |_name, _old, _new|
    Gt4::Guard.install!
  end

  # ---------------------------------------------------------------- #
  #  Admin dashboard routes                                          #
  # ---------------------------------------------------------------- #
  Discourse::Application.routes.append do
    get "/admin/plugins/geetest-captcha" =>
          "admin/plugins#index",
        :constraints => StaffConstraint.new

    scope "/admin/plugins/geetest-captcha", defaults: { format: :json } do
      get    "/status"            => "gt4/admin#status",      constraints: StaffConstraint.new
      get    "/stats"             => "gt4/admin#stats",       constraints: StaffConstraint.new
      delete "/stats"             => "gt4/admin#reset_stats", constraints: StaffConstraint.new
      post   "/test"              => "gt4/admin#test",        constraints: StaffConstraint.new
      put    "/toggle"            => "gt4/admin#toggle",      constraints: StaffConstraint.new
    end
  end
end
