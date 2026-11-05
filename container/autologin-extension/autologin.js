(() => {
  "use strict";

  const expectedHost = "ids-hit-edu-cn-s.hitsz.edu.cn";
  const expectedPath = "/authserver/login";
  const expectedServiceHost = "trust.hitsz.edu.cn";
  const expectedServicePath = "/passport/v1/auth/cas/";
  const attemptKey = "hitszTrustedTerminalSubmitted";
  const deadline = Date.now() + 30_000;
  let stableAutofillChecks = 0;

  function hasExpectedServiceTarget() {
    const service = new URLSearchParams(location.search).get("service");
    if (!service) {
      return false;
    }

    try {
      const target = new URL(service);
      return target.protocol === "https:" &&
        target.hostname === expectedServiceHost &&
        (target.port === "" || target.port === "443") &&
        target.pathname === expectedServicePath &&
        target.searchParams.get("sfDomain") === "hitcas";
    } catch {
      return false;
    }
  }

  if (location.hostname !== expectedHost ||
      !location.pathname.startsWith(expectedPath) ||
      !hasExpectedServiceTarget()) {
    return;
  }
  if (sessionStorage.getItem(attemptKey) === "1") {
    return;
  }

  function isBrowserAutofilled(input) {
    try {
      return input.matches(":-webkit-autofill");
    } catch {
      return false;
    }
  }

  function findSubmitControl(form) {
    return form.querySelector([
      "a#login_submit.login-btn",
      "button#login_submit.login-btn",
      "button[type='submit']",
      "input[type='submit']"
    ].join(","));
  }

  function findRememberControl(form) {
    return form.querySelector(
      "input#rememberMe[type='checkbox'][name='rememberMe'][value='true']"
    );
  }

  let rememberPreselected = false;

  // A persistent CASTGC lets the next relaunch pass CAS SSO without a form.
  // Pre-select remember-me once so a manual noVNC login keeps that benefit;
  // never toggle it back if the user clears it afterwards.
  function preselectRemember(remember) {
    if (rememberPreselected || !remember) {
      return;
    }
    rememberPreselected = true;
    if (!remember.checked) {
      remember.click();
    }
  }

  function tryTrustedSubmit() {
    if (Date.now() >= deadline || sessionStorage.getItem(attemptKey) === "1") {
      return;
    }

    const password = document.querySelector("input[type='password']");
    const form = password && (password.form || password.closest("form"));
    const submit = form && findSubmitControl(form);
    const remember = form && findRememberControl(form);

    preselectRemember(remember);

    if (!password || !form || !submit || !remember ||
        !isBrowserAutofilled(password)) {
      stableAutofillChecks = 0;
      setTimeout(tryTrustedSubmit, 500);
      return;
    }

    stableAutofillChecks += 1;
    if (stableAutofillChecks < 3) {
      setTimeout(tryTrustedSubmit, 500);
      return;
    }

    if (!remember.checked) {
      remember.click();
      if (!remember.checked) {
        return;
      }
    }

    // Store only a one-shot marker. The extension never reads or persists the
    // username/password and has no network permissions.
    sessionStorage.setItem(attemptKey, "1");
    submit.click();
  }

  tryTrustedSubmit();
})();
