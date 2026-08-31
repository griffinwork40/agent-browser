import AppKit
import WebKit

// MARK: - Auth Wall Detection + WebAuthn Handoff
//
// Option D: Passkey Human-Handoff Protocol.
// Detects when a page requires authentication (login forms, WebAuthn ceremonies,
// MFA prompts, CAPTCHAs) and returns a detection result so the calling agent
// can request human handoff. The tab state transition to awaitingAuth is
// initiated by the agent, not by this module.
//
// Also provides a JS injection for detecting WebAuthn ceremony initiation
// (navigator.credentials.create/get) so the agent can proactively hand off
// before the OS modal appears.

extension BrowserAutomationService {

    // MARK: - Auth Status Detection

    /// Detect whether the current page requires authentication.
    /// Returns a typed status with details about what was detected.
    func authStatusCallback(
        tabId: String,
        completion: @escaping (AgentResponse) -> Void
    ) {
        guard let tab = resolveTab(tabId) else {
            completion(.failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(tabId)"))
            return
        }

        let script = Self.authDetectionScript
        tab.webView.evaluateJavaScript(
            script, in: nil, in: .world(name: "AgentBridge")
        ) { resultOrError in
            DispatchQueue.main.async {
                switch resultOrError {
                case .failure(let error):
                    completion(.failure(
                        code: ErrorCode.javaScriptError,
                        message: error.localizedDescription
                    ))
                case .success(let raw):
                    guard let jsonString = raw as? String,
                          let data = jsonString.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        completion(.failure(
                            code: ErrorCode.javaScriptError,
                            message: "Failed to parse auth detection result"
                        ))
                        return
                    }
                    completion(.success(AuthStatusResult(from: dict)))
                }
            }
        }
    }

    /// Async variant.
    func authStatusResponse(tabId: String) async -> AgentResponse {
        guard let tab = resolveTab(tabId) else {
            return .failure(code: ErrorCode.tabNotFound, message: "No tab with id: \(tabId)")
        }

        do {
            let raw = try await evalJSOnTabInBridgeWorld(tab, script: Self.authDetectionScript)
            guard let jsonString = raw as? String,
                  let data = jsonString.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(
                    code: ErrorCode.javaScriptError,
                    message: "Failed to parse auth detection result"
                )
            }
            return .success(AuthStatusResult(from: dict))
        } catch {
            return .failure(
                code: ErrorCode.javaScriptError,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Auth Detection JavaScript

    /// JavaScript that inspects the page for authentication signals.
    /// Runs in the AgentBridge content world for DOM access.
    static let authDetectionScript = """
    JSON.stringify((() => {
        const signals = [];
        const url = window.location.href.toLowerCase();
        const path = window.location.pathname.toLowerCase();

        // 1. URL pattern matching
        const authPaths = [
            '/login', '/signin', '/sign-in', '/sign_in',
            '/auth', '/authenticate', '/sso',
            '/oauth', '/cas/login', '/saml',
            '/account/login', '/accounts/login',
            '/session/new', '/sessions/new',
            '/mfa', '/2fa', '/two-factor',
            '/verify', '/verification',
            '/challenge', '/security-check'
        ];
        for (const p of authPaths) {
            const idx = path.indexOf(p);
            if (idx !== -1 && (idx + p.length === path.length || path[idx + p.length] === '/')) {
                signals.push({ type: 'url_pattern', detail: p });
                break;
            }
        }

        // 2. Password field detection (visible in viewport)
        const pwFields = document.querySelectorAll('input[type="password"]');
        const visiblePw = Array.from(pwFields).filter(el => {
            const r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0 && el.offsetParent !== null;
        });
        if (visiblePw.length > 0) {
            signals.push({ type: 'password_field', detail: visiblePw.length + ' visible' });
        }

        // 3. Login form detection (form with password + submit)
        const forms = document.querySelectorAll('form');
        for (const form of forms) {
            const hasPw = form.querySelector('input[type="password"]');
            const hasSubmit = form.querySelector(
                'button[type="submit"], input[type="submit"], button:not([type])'
            );
            if (hasPw && hasSubmit) {
                signals.push({ type: 'login_form', detail: 'form with password + submit' });
                break;
            }
        }

        // 4. Common login page DOM signals
        const loginSelectors = [
            '[data-testid*="login"]', '[data-testid*="signin"]',
            '[id*="login-form"]', '[id*="signin-form"]',
            '[class*="login-form"]', '[class*="signin-form"]',
            '[aria-label*="Sign in"]', '[aria-label*="Log in"]'
        ];
        for (const sel of loginSelectors) {
            if (document.querySelector(sel)) {
                signals.push({ type: 'dom_signal', detail: sel });
                break;
            }
        }

        // 5. Heading text analysis
        const headings = document.querySelectorAll('h1, h2, h3');
        const authHeadings = ['sign in', 'log in', 'login', 'authenticate',
            'enter your password', 'verify your identity', 'two-factor',
            'security check', 'confirm your identity'];
        for (const h of headings) {
            const text = (h.textContent || '').toLowerCase().trim();
            if (authHeadings.some(ah => text.includes(ah))) {
                signals.push({ type: 'heading', detail: text.substring(0, 80) });
                break;
            }
        }

        // 6. CAPTCHA detection
        const captchaSignals = [
            'iframe[src*="recaptcha"]', 'iframe[src*="hcaptcha"]',
            'iframe[src*="turnstile"]', '[class*="captcha"]',
            '#captcha', '[data-sitekey]'
        ];
        for (const sel of captchaSignals) {
            if (document.querySelector(sel)) {
                signals.push({ type: 'captcha', detail: sel });
                break;
            }
        }

        // 7. MFA / OTP field detection
        const otpInputs = document.querySelectorAll(
            'input[autocomplete="one-time-code"], input[name*="otp"], ' +
            'input[name*="totp"], input[name*="code"][maxlength="6"], ' +
            'input[inputmode="numeric"][maxlength="6"]'
        );
        if (otpInputs.length > 0) {
            signals.push({ type: 'mfa_field', detail: otpInputs.length + ' OTP inputs' });
        }

        // 8. Paywall detection
        const paywallSignals = [
            '[class*="paywall"]', '[id*="paywall"]',
            '[data-testid*="paywall"]', '[class*="subscribe-wall"]'
        ];
        for (const sel of paywallSignals) {
            if (document.querySelector(sel)) {
                signals.push({ type: 'paywall', detail: sel });
                break;
            }
        }

        // 9. Passkey / WebAuthn detection
        // Detect pages requesting passkey or WebAuthn authentication.
        // Checks: URL patterns, heading text, button text, and page content
        // that indicate a passkey ceremony is expected.
        const passkeyUrlPatterns = ['/challenge/pk/', '/passkey', '/webauthn'];
        for (const p of passkeyUrlPatterns) {
            if (path.indexOf(p) !== -1 || url.indexOf(p) !== -1) {
                signals.push({ type: 'passkey_url', detail: p });
                break;
            }
        }

        const passkeyHeadings = [
            'use your passkey', 'passkey', 'security key',
            'confirm it', 'verify it'  // Google: "confirm it's really you"
        ];
        for (const h of headings) {
            const text = (h.textContent || '').toLowerCase().trim();
            if (passkeyHeadings.some(pk => text.includes(pk))) {
                signals.push({ type: 'passkey_heading', detail: text.substring(0, 80) });
                break;
            }
        }

        // Passkey-related button or link text (e.g. "Use a passkey", "Continue" on passkey pages)
        const passkeyButtonTexts = ['use a passkey', 'use passkey', 'sign in with passkey',
            'use your passkey', 'use a security key', 'try another way'];
        const allButtons = document.querySelectorAll('button, a[role="button"], [role="link"]');
        for (const btn of allButtons) {
            const text = (btn.textContent || '').toLowerCase().trim();
            if (passkeyButtonTexts.some(pk => text.includes(pk))) {
                signals.push({ type: 'passkey_button', detail: text.substring(0, 80) });
                break;
            }
        }

        // Detect WebAuthn API presence on the page (conditional UI hints)
        if (typeof PublicKeyCredential !== 'undefined') {
            const conditionalInputs = document.querySelectorAll(
                'input[autocomplete*="webauthn"]'
            );
            if (conditionalInputs.length > 0) {
                signals.push({ type: 'webauthn_conditional', detail: conditionalInputs.length + ' inputs' });
            }
        }

        // Classify the overall status
        let status = 'authenticated';
        const types = signals.map(s => s.type);

        const hasPasskeySignal = types.includes('passkey_url') ||
            types.includes('passkey_heading') || types.includes('passkey_button') ||
            types.includes('webauthn_conditional');

        if (types.includes('captcha')) {
            status = 'captcha_blocked';
        } else if (hasPasskeySignal) {
            status = 'passkey_required';
        } else if (types.includes('mfa_field')) {
            status = 'mfa_required';
        } else if (types.includes('paywall')) {
            status = 'paywall';
        } else if (types.includes('password_field') || types.includes('login_form')) {
            status = 'login_required';
        } else if (types.includes('url_pattern') && (
            types.includes('heading') || types.includes('dom_signal')
        )) {
            // URL pattern alone is weak; need corroboration
            status = 'login_required';
        } else if (types.includes('url_pattern')) {
            status = 'session_expired';  // URL suggests auth but no form visible yet
        }

        return {
            status: status,
            url: window.location.origin + window.location.pathname,
            title: document.title,
            signals: signals
        };
    })())
    """
}

// MARK: - Auth Status Result

struct AuthStatusResult: Codable, Sendable {
    let status: String       // authenticated | login_required | session_expired |
                              // mfa_required | captcha_blocked | paywall |
                              // passkey_required
    let url: String
    let title: String
    let signals: [[String: String]]

    init(from dict: [String: Any]) {
        // Default to "unknown" rather than "authenticated" so a missing/invalid
        // status field does not silently report the page as authenticated.
        self.status = dict["status"] as? String ?? "unknown"
        self.url = dict["url"] as? String ?? ""
        let rawTitle = dict["title"] as? String ?? ""
        self.title = Self.sanitize(rawTitle, maxLength: 256)

        if let sigs = dict["signals"] as? [[String: Any]] {
            self.signals = sigs.map { sig in
                var entry: [String: String] = [:]
                for (k, v) in sig { entry[k] = "\(v)" }
                return entry
            }
        } else {
            self.signals = []
        }
    }

    /// Sanitize a page title: truncate to `maxLength` grapheme clusters (preserving
    /// cluster boundaries) and strip all ASCII control characters (< 0x20).
    /// Page titles never legitimately contain newlines or tabs.
    private static func sanitize(_ raw: String, maxLength: Int) -> String {
        let truncated = raw.count > maxLength ? String(raw.prefix(maxLength)) : raw
        return truncated.unicodeScalars.filter { $0.value >= 0x20 }
            .reduce(into: "") { $0 += String($1) }
    }
}
