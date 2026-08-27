/// The version both halves of the product report.
///
/// Its purpose is comparison, not display: the daemon keeps running across an
/// install, so a freshly built CLI or app routinely talks to a daemon from the
/// previous build. Knowing that is the difference between "this field is missing"
/// and "this daemon is old".
public enum DranikVersion {
    public static let current = "0.1.0"
}
