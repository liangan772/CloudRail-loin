import { withPluginApi } from "discourse/lib/plugin-api";
import GeetestWidget from "../lib/geetest-widget";

const GT4_FIELDS = ["lot_number", "captcha_output", "pass_token", "gen_time"];

const SIGNUP_SELECTORS = ["form#create-account-form", ".create-account form"];
const LOGIN_SELECTORS = ["form#login-form", ".login-modal form"];

function enabled() {
  return settings.geetest_captcha_enabled && settings.geetest_captcha_id;
}

function buildWidget(mountId) {
  return new GeetestWidget({
    captchaId: settings.geetest_captcha_id,
    product: settings.geetest_captcha_product || "bind",
    language: settings.geetest_captcha_language || "zho",
    mountSelector: `#${mountId}`,
  });
}

function injectHiddenFields(form, payload) {
  GT4_FIELDS.forEach((field) => {
    let input = form.querySelector(`input[name="${field}"]`);
    if (!input) {
      input = document.createElement("input");
      input.type = "hidden";
      input.name = field;
      form.appendChild(input);
    }
    input.value = (payload && payload[field]) || "";
  });
}

function clearHiddenFields(form) {
  form.querySelectorAll('input[name="lot_number"]').forEach((input) => {
    input.value = "";
  });
}

/**
 * Gates a form behind a GT4 challenge.
 *
 * The first submit is intercepted and prevented. We run the challenge,
 * write the resulting payload into hidden inputs, then replay the submit.
 * The replayed submit passes straight through because `lot_number` is now
 * populated, so the native form submission (and its CSRF token) is
 * untouched.
 */
function gateForm(form, widget) {
  if (form.dataset.gt4Gated === "true") {
    return;
  }
  form.dataset.gt4Gated = "true";

  form.addEventListener(
    "submit",
    async (event) => {
      const lotField = form.querySelector('input[name="lot_number"]');
      if (lotField && lotField.value) {
        // Payload already attached: this is our replayed submit.
        return;
      }

      event.preventDefault();
      event.stopImmediatePropagation();

      let payload = null;
      try {
        payload = await widget.show();
      } catch (error) {
        // eslint-disable-next-line no-console
        console.error("[geetest-captcha] verification failed to run", error);
        widget.reset();
      }

      if (!payload) {
        clearHiddenFields(form);
        return;
      }

      injectHiddenFields(form, payload);
      if (form.requestSubmit) {
        form.requestSubmit();
      } else {
        form.submit();
      }
    },
    true,
  );
}

export default {
  name: "geetest-captcha",

  initialize() {
    if (!enabled()) {
      return;
    }

    withPluginApi("1.0.0", (api) => {
      const widgets = new Map();
      let mountSeq = 0;

      const widgetFor = (scope) => {
        if (!widgets.has(scope)) {
          mountSeq += 1;
          const mountId = `gt4-captcha-mount-${scope}-${mountSeq}`;
          const host = document.createElement("div");
          host.id = mountId;
          host.className = "gt4-captcha-mount";
          document.body.appendChild(host);
          widgets.set(scope, buildWidget(mountId));
        }
        return widgets.get(scope);
      };

      // ---------------- Signup & login forms -------------------
      if (settings.geetest_captcha_on_signup || settings.geetest_captcha_on_login) {
        const scanAuthForms = () => {
          if (settings.geetest_captcha_on_signup) {
            SIGNUP_SELECTORS.forEach((selector) =>
              document
                .querySelectorAll(selector)
                .forEach((form) => gateForm(form, widgetFor("signup"))),
            );
          }
          if (settings.geetest_captcha_on_login) {
            LOGIN_SELECTORS.forEach((selector) =>
              document
                .querySelectorAll(selector)
                .forEach((form) => gateForm(form, widgetFor("login"))),
            );
          }
        };

        api.onPageChange(scanAuthForms);
        // Auth modals are mounted asynchronously; re-scan shortly after.
        api.onAppEvent("modal:body-shown", () => setTimeout(scanAuthForms, 0));
      }

      // ---------------- Composer (new topic / reply) ------------
      if (settings.geetest_captcha_on_post) {
        api.composerBeforeSave(async () => {
          const widget = widgetFor("post");
          const payload = await widget.show();

          if (!payload) {
            // Returning a rejected promise aborts the save and surfaces
            // the reason in the composer.
            // eslint-disable-next-line no-throw-literal
            throw I18n.t("geetest_captcha.verify_first");
          }

          const composer = api.container.lookup("service:composer");
          GT4_FIELDS.forEach((field) => composer.set(field, payload[field]));

          // Clear the local pass so the next post re-verifies.
          widget.reset();
        });
      }
    });
  },
};

export { GT4_FIELDS };
