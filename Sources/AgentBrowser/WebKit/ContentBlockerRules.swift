import Foundation

/// Bundled fallback content-blocking rules in Safari Content Blocker JSON format.
///
/// Used when the network is unavailable or before the first EasyList/EasyPrivacy
/// download completes. Covers the most common ad networks and trackers so blocking
/// works out-of-the-box without any download step.
///
/// Format: `[{"trigger": {"url-filter": "..."}, "action": {"type": "block"}}]`
/// Patterns use regular-expression syntax compatible with WKContentRuleListStore.
enum ContentBlockerRules {

    /// Identifier used when compiling the fallback list.
    static let fallbackIdentifier = "com.agentbrowser.blocklist.fallback"

    /// JSON string for the bundled fallback block list.
    /// Rules target the most impactful ad/tracker domains by URL pattern.
    static let fallbackJSON: String = """
    [
      {"trigger":{"url-filter":".*\\\\.doubleclick\\\\.net\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.googlesyndication\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.googleadservices\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.google-analytics\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.googletagmanager\\\\.com\\\\/gtm\\\\.js"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.googletagservices\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.facebook\\\\.net\\\\/tr\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.facebook\\\\.net\\\\/signals\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*connect\\\\.facebook\\\\.net\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.ads\\\\.twitter\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.analytics\\\\.twitter\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.amazon-adsystem\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.adsafeprotected\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.moatads\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.scorecardresearch\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.quantserve\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.adnxs\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.rubiconproject\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.pubmatic\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.openx\\\\.net\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.openx\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.criteo\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.criteo\\\\.net\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.outbrain\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.taboola\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.bidswitch\\\\.net\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.casalemedia\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.33across\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.sharethrough\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.sovrn\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.lijit\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.adsrvr\\\\.org\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.thetradedesk\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.turn\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.mixpanel\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.segment\\\\.com\\\\/v1\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.segment\\\\.io\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.amplitude\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.hotjar\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.fullstory\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.logrocket\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.heap\\\\.io\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.heapanalytics\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.mouseflow\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.crazyegg\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.parsely\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.chartbeat\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.newrelic\\\\.com\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.nr-data\\\\.net\\\\/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\\\.datadog-browser-agent\\\\.com\\\\/"},"action":{"type":"block"}}
    ]
    """
}
