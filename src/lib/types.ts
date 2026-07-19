// Shapes matching public/data/forecast.json exactly — see sql/05_export_proc.sql.
// No transformation logic lives here; this is a straight read of the artifact.

export type Direction = "departure" | "arrival";
export type Daypart = "breakfast" | "lunch" | "dinner" | "off";

export interface Flight {
  flightId: number;
  airline: string;
  airlineIataCode: string;
  flightNumber: string;
  direction: Direction;
  scheduledTime: string;
  aircraftType: string;
  seats: number;
  loadFactor: number;
  passengers: number;
  gate: string;
  gateZone: string;
  geometryWeight: number;
  passengersPastA36: number;
  dwellFraction: number;
  otherAirportCode: string;
  otherAirportCity: string;
  durationMinutes: number | null; // live-ingested flights don't have this — Aviation Edge's schedule endpoint gives no elapsed time
  impactWindowStart: string;
  impactWindowEnd: string;
}

export interface Hour {
  hour: number;
  daypart: Daypart;
  index: number;
  flights: Flight[]; // only flights with a resolved gate — see inferredFlightCount
  // Flights this hour with no resolved gate, whose exposure still cleared
  // the display threshold (via an airline's own empirical geometry-weight
  // prior, not a known gate — see mdl.FlightExposure). Collapsed into a
  // count and a total rather than listed individually: an inferred flight
  // is weaker evidence than a real gate, and itemizing dozens of them
  // reads as noise, not credibility.
  inferredFlightCount: number;
  inferredExposure: number;
}

export interface Day {
  date: string;
  dayOfWeek: string;
  openHour: number;
  closeHour: number;
  dayIndex: number;
  peakHour: number;
  hours: Hour[];
}

export interface OpenHoursEntry {
  dayOfWeek: number;
  openHour: number;
  closeHour: number;
}

export interface DaypartWindow {
  daypart: string;
  startHour: number;
  endHour: number;
}

export interface Location {
  locationId: number;
  airportCode: string;
  gateLabel: string;
  displayName: string;
  terminalName: string;
  city: string;
}

// The picker's source list — public/data/locations.json. A separate, much
// smaller artifact than any one location's forecast, so the picker can
// list what else is available without fetching every location's full
// forecast just to read their names.
export interface LocationManifestEntry extends Location {
  forecastFile: string; // -> /data/forecast-{forecastFile}.json
}

export interface Forecast {
  generatedAt: string;
  source: string;
  orderCycleDays: number;
  windowDays: number; // one window's span in days; days.length is a multiple of this
  location: Location;
  defaultLoadFactor: number;
  openHoursByDayOfWeek: OpenHoursEntry[];
  daypartWindows: DaypartWindow[];
  days: Day[];
}
