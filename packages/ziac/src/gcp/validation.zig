pub const ValidationError = error{
    MissingProjectId,
    MissingRegion,
    MissingName,
    MissingImage,
    InvalidPort,
    DuplicateEnvVar,
    MissingLabel,
    PremiumTierRequired,
};
