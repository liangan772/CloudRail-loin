import loadGeetest from "./geetest-loader";

/**
 * Thin promise-based wrapper around a GeeTest CAPTCHA v4 instance.
 *
 * In `bind` mode the widget renders no visible button: the host page
 * calls `show()` when the user presses submit, and we resolve once the
 * challenge has passed. That is exactly the interaction we want on
 * Discourse forms, where the native submit button should stay the
 * single call-to-action.
 */
export default class GeetestWidget {
  constructor(options = {}) {
    this.captchaId = options.captchaId;
    this.product = options.product || "bind";
    this.language = options.language || "zho";
    this.scriptUrl = options.scriptUrl;
    this.mountSelector = options.mountSelector || "#gt4-captcha-mount";

    this.instance = null;
    this.ready = false;
    this.result = null;
    this._readyResolve = null;
    this._readyPromise = null;

    this._buildReadyPromise();
  }

  _buildReadyPromise() {
    this._readyPromise = new Promise((resolve) => {
      this._readyResolve = resolve;
    });
  }

  /**
   * Initialises the widget. Safe to call multiple times.
   */
  async init() {
    if (this.instance || this._initPromise) {
      return this._initPromise;
    }

    this._initPromise = (async () => {
      const initGeetest4 = await loadGeetest(this.scriptUrl);

      return new Promise((resolve, reject) => {
        let host = document.querySelector(this.mountSelector);
        if (!host) {
          host = document.createElement("div");
          host.id = this.mountSelector.replace(/^#/, "");
          document.body.appendChild(host);
        }

        initGeetest4(
          {
            captchaId: this.captchaId,
            product: this.product,
            language: this.language,
            protocol: `${window.location.protocol}//`,
          },
          (captchaObj) => {
            this.instance = captchaObj;

            captchaObj.onReady(() => {
              this.ready = true;
              this._readyResolve(captchaObj);
            });

            captchaObj.onSuccess(() => {
              this.result = captchaObj.getValidate();
            });

            captchaObj.onError(() => {
              this.result = null;
            });

            // `bind` mode cannot use appendTo; popup/float can.
            if (this.product !== "bind" && typeof captchaObj.appendTo === "function") {
              captchaObj.appendTo(this.mountSelector);
            }

            resolve(captchaObj);
          },
        );
      }).catch((error) => {
        this._initPromise = null;
        throw error;
      });
    })();

    return this._initPromise;
  }

  /**
   * Triggers the challenge and resolves with the GT4 payload once the
   * user passes it. Resolves with `null` if the user closes the widget.
   */
  async show() {
    const captchaObj = await this.init();
    await this._readyPromise;

    if (this.result) {
      return this.result;
    }

    return new Promise((resolve) => {
      let settled = false;

      const finish = (value) => {
        if (settled) {
          return;
        }
        settled = true;
        resolve(value);
      };

      // `onSuccess` may fire before our cached `this.result` is updated,
      // so always read `getValidate()` directly inside the handler.
      // Registering once (guarded below) avoids stacking handlers across
      // repeated `show()` calls.
      if (!this._bound) {
        this._bound = true;
        captchaObj.onSuccess(() => {
          this.result = captchaObj.getValidate();
          if (this._pendingFinish) {
            this._pendingFinish(this.result);
          }
        });
        if (typeof captchaObj.onClose === "function") {
          captchaObj.onClose(() => {
            if (this._pendingFinish) {
              this._pendingFinish(null);
            }
          });
        }
      }

      this._pendingFinish = (value) => {
        this._pendingFinish = null;
        finish(value);
      };

      captchaObj.showCaptcha();
    });
  }

  /**
   * Clears a previous pass so the next `show()` starts fresh. Call this
   * whenever the surrounding business request failed and the user must
   * verify again.
   */
  reset() {
    this.result = null;
    if (this.instance && typeof this.instance.reset === "function") {
      this.instance.reset();
    }
  }

  destroy() {
    this.result = null;
    this.ready = false;
    if (this.instance && typeof this.instance.destroy === "function") {
      this.instance.destroy();
    }
    this.instance = null;
    this._initPromise = null;
    this._buildReadyPromise();
  }
}
