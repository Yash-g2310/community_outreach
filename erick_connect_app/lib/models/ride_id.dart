/// FastAPI ride identifiers are UUIDs, not numeric primary keys.
///
/// Keeping this alias in the shared client contract prevents new code from
/// reintroducing `int` ride IDs in the client.
typedef RideId = String;
