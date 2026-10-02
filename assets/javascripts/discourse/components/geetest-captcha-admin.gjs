import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { fn, concat } from "@ember/helper";
import { eq, or, not } from "discourse/helpers/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

const BASE = "/admin/plugins/geetest-captcha";

const GROUP_ORDER = ["basic", "scopes", "advanced"];

/**
 * Admin dashboard body for the GeeTest CAPTCHA v4 plugin.
 *
 * This is the *single* configuration surface for the plugin: every site
 * setting the plugin owns is rendered here, grouped into sections, and
 * saved in one atomic request. The built-in Discourse settings page still
 * works for compatibility, but nothing requires visiting it.
 *
 * Authored as a `.gjs` single-file component: the template is inline in
 * `<template>` and every helper is imported explicitly. This is the
 * forward-looking format Discourse is migrating to, and the direct
 * replacement for the deprecated `.hbs` theme/plugin template extension
 * (https://meta.discourse.org/t/398896).
 */
export default class GeetestCaptchaAdmin extends Component {
  @service dialog;

  @tracked loading = true;
  @tracked saving = false;

  /** Server-authoritative state. */
  @tracked server = null;
  /** Local, editable draft. */
  @tracked draft = {};

  @tracked fieldErrors = {};
  @tracked stats = null;
  @tracked statDays = 7;
  @tracked testing = false;
  @tracked testResult = null;

  constructor() {
    super(...arguments);
    this.load();
  }

  // ------------------------------------------------------------------ //
  //  Derived state                                                     //
  // ------------------------------------------------------------------ //

  get groups() {
    return GROUP_ORDER.filter((g) => this.fieldsForGroup(g).length > 0);
  }

  get health() {
    return this.server?.health || null;
  }

  get healthOk() {
    return Boolean(this.health?.ok);
  }

  get checks() {
    return this.health?.checks || [];
  }

  /** Settings belonging to `group`, in server-provided order. */
  fieldsForGroup(group) {
    const all = this.server?.settings || {};
    return Object.entries(all)
      .filter(([, meta]) => meta.group === group)
      .map(([key, meta]) => ({ key, ...meta }));
  }

  get dirtyKeys() {
    if (!this.server) {
      return [];
    }

    return Object.keys(this.server.settings).filter((key) => {
      const meta = this.server.settings[key];
      // A blank secret means "leave the stored value alone" — it is
      // never considered a pending change.
      if (meta.type === "secret" && this.draft[key] === "") {
        return false;
      }
      return this.normalize(this.draft[key]) !== this.normalize(meta.value);
    });
  }

  get isDirty() {
    return this.dirtyKeys.length > 0;
  }

  get dirtyLabel() {
    const n = this.dirtyKeys.length;
    if (n === 0) {
      return null;
    }
    return i18n("geetest_captcha.admin.form.unsaved_count", { count: n });
  }

  get statCards() {
    const summary = this.stats?.summary || {};
    return ["pass", "fail", "degraded", "missing", "total"].map((key) => ({
      key,
      label: i18n(`geetest_captcha.admin.stats.${key}`),
      value: summary[key] ?? 0,
    }));
  }

  get hasStats() {
    return (this.stats?.summary?.total || 0) > 0;
  }

  get dayOptions() {
    return [1, 7, 30];
  }

  /** Enum choices with a human label where we have one. */
  choicesFor(field) {
    return (field.choices || []).map((value) => ({
      value,
      label: i18n(`geetest_captcha.admin.options.${field.label}.${value}`),
    }));
  }

  normalize(value) {
    if (value === null || value === undefined) {
      return "";
    }
    return String(value);
  }

  /**
   * Read the editable draft value for a setting.
   *
   * Glimmer templates cannot do `this.draft.[dynamicKey]`, so all field
   * bindings go through this accessor instead.
   */
  valueFor(key) {
    const value = this.draft[key];
    return value === null || value === undefined ? "" : value;
  }

  isChecked(key) {
    return this.valueFor(key) === true;
  }

  isSelected(key, candidate) {
    return this.normalize(this.valueFor(key)) === this.normalize(candidate);
  }

  errorFor(key) {
    return this.fieldErrors[key];
  }

  /**
   * Human label for a setting.
   *
   * Scope toggles reuse the shorter `scopes.*` strings, everything else
   * uses the `detail.*` table, so the two namespaces do not have to
   * duplicate each other.
   */
  labelFor(field) {
    const namespace =
      field.group === "scopes" ? "scopes" : "detail";
    return i18n(`geetest_captcha.admin.${namespace}.${field.label}`);
  }

  /** Fingerprint hint for a masked field that already has a value. */
  placeholderFor(field) {
    if (field.type === "secret") {
      return field.set
        ? i18n("geetest_captcha.admin.form.secret_placeholder_set", {
            fingerprint: field.fingerprint,
          })
        : i18n("geetest_captcha.admin.form.secret_placeholder_empty");
    }

    // `captcha_id` is masked too, but is a normal text input: show the
    // stored fingerprint as the placeholder so the admin can see *which*
    // id is deployed without overwriting it by accident.
    if (field.masked && field.set) {
      return field.fingerprint;
    }

    return "";
  }

  helpFor(field) {
    const key = `geetest_captcha.admin.help.${field.label}`;
    const text = i18n(key);
    return text.startsWith("translation missing") ? null : text;
  }

  // ------------------------------------------------------------------ //
  //  Data loading                                                      //
  // ------------------------------------------------------------------ //

  @action
  async load() {
    this.loading = true;
    try {
      const response = await ajax(`${BASE}/settings`);
      this.adoptServerState(response);
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
    await this.loadStats();
  }

  adoptServerState(response) {
    this.server = response;

    const next = {};
    for (const [key, meta] of Object.entries(response.settings || {})) {
      // Secrets always start blank: we never render the stored value,
      // and a blank submission is a no-op on the server.
      next[key] = meta.type === "secret" ? "" : (meta.value ?? "");
    }
    this.draft = next;
    this.fieldErrors = {};
  }

  @action
  async loadStats() {
    try {
      this.stats = await ajax(`${BASE}/stats?days=${this.statDays}`);
    } catch {
      // Statistics are non-critical: keep the rest of the page usable.
      this.stats = null;
    }
  }

  @action
  async changeDays(days) {
    this.statDays = days;
    await this.loadStats();
  }

  // ------------------------------------------------------------------ //
  //  Form editing                                                      //
  // ------------------------------------------------------------------ //

  @action
  updateField(key, event) {
    const value = event?.target ? event.target.value : event;
    this.draft = { ...this.draft, [key]: value };

    if (this.fieldErrors[key]) {
      const { [key]: _removed, ...rest } = this.fieldErrors;
      this.fieldErrors = rest;
    }
  }

  @action
  toggleField(key) {
    this.draft = { ...this.draft, [key]: !this.draft[key] };
    if (this.fieldErrors[key]) {
      const { [key]: _removed, ...rest } = this.fieldErrors;
      this.fieldErrors = rest;
    }
  }

  @action
  undo() {
    if (!this.server) {
      return;
    }
    this.adoptServerState(this.server);
  }

  // ------------------------------------------------------------------ //
  //  Saving                                                            //
  // ------------------------------------------------------------------ //

  @action
  async save() {
    if (this.saving || !this.isDirty) {
      return;
    }

    this.saving = true;
    this.fieldErrors = {};

    // Only send what actually changed, so an untouched secret is never
    // transmitted.
    const payload = {};
    for (const key of this.dirtyKeys) {
      payload[key] = this.draft[key];
    }

    try {
      const response = await ajax(`${BASE}/settings`, {
        type: "PUT",
        data: { settings: payload },
      });
      this.adoptServerState(response);
      this.flashSuccess();
    } catch (e) {
      const body = e?.jqXHR?.responseJSON || e?.responseJSON;
      if (body?.errors) {
        this.fieldErrors = Object.fromEntries(
          Object.entries(body.errors).map(([k, v]) => [k, v.join("；")])
        );
        // Keep the draft intact so the admin can correct the input.
        this.server = { ...this.server, health: body.health || this.server.health };
      } else {
        popupAjaxError(e);
      }
    } finally {
      this.saving = false;
    }
  }

  flashSuccess() {
    // Discourse's own `dialog` is a modal; for a non-blocking toast we
    // lean on the built-in notice element when present.
    const notice = document.createElement("div");
    notice.className = "gt4-admin__toast";
    notice.textContent = i18n("geetest_captcha.admin.form.saved");
    document.body.appendChild(notice);
    setTimeout(() => notice.remove(), 2400);
  }

  // ------------------------------------------------------------------ //
  //  Diagnostics                                                       //
  // ------------------------------------------------------------------ //

  @action
  async runTest() {
    this.testing = true;
    this.testResult = null;
    try {
      const response = await ajax(`${BASE}/test`, { type: "POST" });
      this.testResult = response.result;
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.testing = false;
    }
  }

  @action
  async resetStats() {
    try {
      await this.dialog.yesNoConfirm({
        message: i18n("geetest_captcha.admin.stats.reset_confirm"),
      });
    } catch {
      return; // cancelled
    }

    try {
      await ajax(`${BASE}/stats`, { type: "DELETE" });
      await this.loadStats();
    } catch (e) {
      popupAjaxError(e);
    }
  }

  <template>
    <div class="gt4-admin">
      <div class="gt4-admin__header">
        <div>
          <h2>{{i18n "geetest_captcha.admin.title"}}</h2>
          <p class="gt4-admin__subtitle">{{i18n "geetest_captcha.admin.subtitle"}}</p>
        </div>
        <div class="gt4-admin__header-actions">
          {{#if this.dirtyLabel}}
            <span class="gt4-admin__dirty">{{this.dirtyLabel}}</span>
          {{/if}}
          <DButton
            @label="geetest_captcha.admin.refresh"
            @icon="sync"
            @action={{this.load}}
            @disabled={{this.saving}}
            class="btn-default gt4-admin__refresh"
          />
        </div>
      </div>

      {{#if this.loading}}
        <div class="gt4-admin__loading">{{i18n "geetest_captcha.admin.loading"}}</div>
      {{else if this.server}}
        {{! ---- health banner ---- }}
        <section class="gt4-admin__card">
          <h3>{{i18n "geetest_captcha.admin.sections.health"}}</h3>
          <div class="gt4-admin__health {{if this.healthOk 'is-ok' 'is-bad'}}">
            <span class="gt4-admin__dot"></span>
            {{#if this.healthOk}}
              {{i18n "geetest_captcha.admin.health_ok"}}
            {{else}}
              {{i18n "geetest_captcha.admin.health_bad"}}
            {{/if}}
          </div>
          <ul class="gt4-admin__checks">
            {{#each this.checks as |check|}}
              <li class={{if check.ok "is-ok" "is-bad"}}>
                <span class="gt4-admin__check-icon">{{if check.ok "✓" "✕"}}</span>
                {{check.label}}
              </li>
            {{/each}}
          </ul>
        </section>

        {{! ---- configuration form ---- }}
        <section class="gt4-admin__card gt4-admin__card--form">
          <h3>{{i18n "geetest_captcha.admin.sections.config"}}</h3>

          {{#each this.groups as |group|}}
            <fieldset class="gt4-admin__group">
              <legend class="gt4-admin__group-title">
                {{i18n (concat "geetest_captcha.admin.groups." group)}}
              </legend>

              {{#each (this.fieldsForGroup group) as |field|}}
                <div
                  class="gt4-admin__field gt4-admin__field--{{field.type}}"
                  data-setting={{field.key}}
                >
                  <label class="gt4-admin__field-label" for="gt4-{{field.key}}">
                    {{this.labelFor field}}
                    {{#if field.required}}
                      <span class="gt4-admin__required" title="*">*</span>
                    {{/if}}
                  </label>

                  <div class="gt4-admin__field-control">
                    {{#if (eq field.type "boolean")}}
                      <label class="gt4-admin__toggle">
                        <input
                          id="gt4-{{field.key}}"
                          type="checkbox"
                          checked={{this.isChecked field.key}}
                          {{on "change" (fn this.toggleField field.key)}}
                        />
                        <span class="gt4-admin__toggle-text">
                          {{if
                            (this.isChecked field.key)
                            (i18n "geetest_captcha.admin.values.on")
                            (i18n "geetest_captcha.admin.values.off")
                          }}
                        </span>
                      </label>

                    {{else if (eq field.type "enum")}}
                      <select
                        id="gt4-{{field.key}}"
                        class="gt4-admin__select"
                        {{on "change" (fn this.updateField field.key)}}
                      >
                        {{#each (this.choicesFor field) as |choice|}}
                          <option
                            value={{choice.value}}
                            selected={{this.isSelected field.key choice.value}}
                          >
                            {{choice.label}}
                          </option>
                        {{/each}}
                      </select>

                    {{else if (eq field.type "secret")}}
                      <input
                        id="gt4-{{field.key}}"
                        type="password"
                        autocomplete="new-password"
                        class="gt4-admin__input"
                        placeholder={{this.placeholderFor field}}
                        value={{this.valueFor field.key}}
                        {{on "input" (fn this.updateField field.key)}}
                      />

                    {{else}}
                      <input
                        id="gt4-{{field.key}}"
                        type="text"
                        class="gt4-admin__input"
                        placeholder={{this.placeholderFor field}}
                        value={{this.valueFor field.key}}
                        {{on "input" (fn this.updateField field.key)}}
                      />
                    {{/if}}

                    {{#if (this.errorFor field.key)}}
                      <p class="gt4-admin__field-error">{{this.errorFor field.key}}</p>
                    {{else if (this.helpFor field)}}
                      <p class="gt4-admin__field-help">{{this.helpFor field}}</p>
                    {{/if}}
                  </div>
                </div>
              {{/each}}
            </fieldset>
          {{/each}}

          <div class="gt4-admin__form-actions">
            <DButton
              @label={{if
                this.saving
                "geetest_captcha.admin.form.saving"
                "geetest_captcha.admin.form.save"
              }}
              @icon="check"
              @action={{this.save}}
              @disabled={{or this.saving (not this.isDirty)}}
              class="btn-primary"
            />
            <DButton
              @label="geetest_captcha.admin.form.undo"
              @icon="undo"
              @action={{this.undo}}
              @disabled={{or this.saving (not this.isDirty)}}
              class="btn-default"
            />
            {{#if this.isDirty}}
              <span class="gt4-admin__form-hint">
                {{i18n "geetest_captcha.admin.form.unsaved_hint"}}
              </span>
            {{/if}}
          </div>
        </section>

        {{! ---- connectivity test ---- }}
        <section class="gt4-admin__card">
          <h3>{{i18n "geetest_captcha.admin.sections.test"}}</h3>
          <DButton
            @label={{if
              this.testing
              "geetest_captcha.admin.test.running"
              "geetest_captcha.admin.test.run"
            }}
            @action={{this.runTest}}
            @disabled={{this.testing}}
            class="btn-default"
          />
          {{#if this.testResult}}
            <div
              class="gt4-admin__test-result {{if
                this.testResult.reachable
                'is-ok'
                'is-bad'
              }}"
            >
              {{#if this.testResult.reachable}}
                {{i18n
                  "geetest_captcha.admin.test.reachable"
                  ms=this.testResult.latency_ms
                }}
              {{else}}
                {{i18n "geetest_captcha.admin.test.unreachable"}}
              {{/if}}
              <div class="gt4-admin__test-detail">{{this.testResult.detail}}</div>
            </div>
          {{/if}}
        </section>

        {{! ---- statistics ---- }}
        <section class="gt4-admin__card">
          <div class="gt4-admin__card-head">
            <h3>{{i18n "geetest_captcha.admin.sections.stats"}}</h3>
            <div class="gt4-admin__range">
              {{#each this.dayOptions as |days|}}
                <DButton
                  @label={{concat days ""}}
                  @action={{fn this.changeDays days}}
                  class="btn-small {{if
                    (eq this.statDays days)
                    'btn-primary'
                    'btn-default'
                  }}"
                />
              {{/each}}
            </div>
          </div>

          <div class="gt4-admin__stat-grid">
            {{#each this.statCards as |card|}}
              <div class="gt4-admin__stat gt4-admin__stat--{{card.key}}">
                <div class="gt4-admin__stat-value">{{card.value}}</div>
                <div class="gt4-admin__stat-label">{{card.label}}</div>
              </div>
            {{/each}}
          </div>

          {{#unless this.hasStats}}
            <p class="gt4-admin__empty">{{i18n "geetest_captcha.admin.stats.empty"}}</p>
          {{/unless}}

          <DButton
            @label="geetest_captcha.admin.stats.reset"
            @action={{this.resetStats}}
            class="btn-danger btn-small"
          />
        </section>
      {{/if}}
    </div>
  </template>
}
