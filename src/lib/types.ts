// Shapes matching public/data/forecast.json exactly — see sql/05_export_proc.sql.
// No transformation logic lives here; this is a straight read of the artifact.

export type Direction = "departure" | "arrival";
export type Daypart = "breakfast" | "lunch" | "dinner" | "off";

export interface Flight {
  flightId: number;
  airline: string;
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
  flights: Flight[];
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

export interface Forecast {
  generatedAt: string;
  source: string;
  orderCycleDays: number;
  defaultLoadFactor: number;
  openHoursByDayOfWeek: OpenHoursEntry[];
  daypartWindows: DaypartWindow[];
  days: Day[];
}
