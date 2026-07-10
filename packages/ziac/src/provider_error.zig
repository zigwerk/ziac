pub const ProviderError = error{
    AuthenticationFailed,
    AuthorizationFailed,
    InvalidConfiguration,
    Conflict,
    NotFound,
    QuotaExceeded,
    RateLimited,
    TransientFailure,
    ProviderTimeout,
    ProviderCancelled,
    ProviderBug,
    OutOfMemory,
};

pub const Category = enum {
    authentication,
    authorization,
    invalid_configuration,
    conflict,
    not_found,
    quota,
    rate_limited,
    transient,
    timeout,
    cancelled,
    provider_bug,
};

pub fn category(err: ProviderError) Category {
    return switch (err) {
        error.AuthenticationFailed => .authentication,
        error.AuthorizationFailed => .authorization,
        error.InvalidConfiguration => .invalid_configuration,
        error.Conflict => .conflict,
        error.NotFound => .not_found,
        error.QuotaExceeded => .quota,
        error.RateLimited => .rate_limited,
        error.TransientFailure => .transient,
        error.ProviderTimeout => .timeout,
        error.ProviderCancelled => .cancelled,
        error.ProviderBug, error.OutOfMemory => .provider_bug,
    };
}
