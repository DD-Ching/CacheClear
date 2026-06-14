//
//  SponsorAd.swift
//  CacheClear
//
//  One slot in the swappable sponsor/ad frame shown during scan + upload (free
//  users only). The author fully controls what goes here: the built-in "support
//  the author" card by default, or — when a cloud feed is configured — their own
//  app promos, affiliate links, or a sold sponsor image. No third-party ad SDK,
//  no tracking: a sponsor ad is just a headline + optional image + a link the
//  author chose. (macOS has no usable mobile-style ad network; this self-served
//  slot is the clean, ban-free way to run ads — and it can be sold to a sponsor.)
//

import Foundation

struct SponsorAd: Identifiable, Equatable {
    let id: String
    var headline: String
    var subhead: String?
    var symbol: String?        // SF Symbol for built-in / local ads
    var imageURL: URL?         // remote artwork for cloud-served ads
    var linkURL: URL?          // tap target; nil on the support-author ad
    var isSupportAuthor: Bool = false

    /// The default slot content: a gentle "thank you / support the author" card.
    static var supportAuthor: SponsorAd {
        SponsorAd(
            id: "support-author",
            headline: NSLocalizedString("support.card.thanks", comment: ""),
            subhead: NSLocalizedString("sponsor.support_sub", comment: ""),
            symbol: "heart.fill",
            isSupportAuthor: true
        )
    }
}

// Decoded from the author's hosted feed: [{ id, headline, subhead?, imageURL?, linkURL? }].
// (init(from:) lives in an extension so the memberwise initializer is preserved.)
extension SponsorAd: Decodable {
    enum CodingKeys: String, CodingKey { case id, headline, subhead, imageURL, linkURL }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(String.self, forKey: .id)
        headline = try c.decode(String.self, forKey: .headline)
        subhead  = try c.decodeIfPresent(String.self, forKey: .subhead)
        imageURL = try c.decodeIfPresent(URL.self, forKey: .imageURL)
        linkURL  = try c.decodeIfPresent(URL.self, forKey: .linkURL)
        symbol = nil
        isSupportAuthor = false
    }
}
