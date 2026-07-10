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
    RemoteOperationFailed,
    DestructiveConfirmationRequired,
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
    remote_operation,
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
        error.RemoteOperationFailed => .remote_operation,
        error.DestructiveConfirmationRequired => .invalid_configuration,
        error.ProviderBug, error.OutOfMemory => .provider_bug,
    };
}
