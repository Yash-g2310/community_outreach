/// FastAPI ride identifiers are UUIDs, not numeric Django primary keys.
///
/// Keeping this alias in the shared client contract prevents new code from
/// reintroducing `int` ride IDs while the legacy screens are migrated.
typedef RideId = String;
