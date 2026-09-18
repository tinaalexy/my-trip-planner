export interface User {
  id: string
  username: string
}

export interface Trip {
  id: string
  destination: string
  startDate: string
  endDate: string
  tripType: string
  createdAt: string
}

export interface Activity {
  id: string
  tripId: string
  dayIndex: number
  text: string
  createdAt: string
  updatedAt: string
}

export interface TripDetail extends Trip {
  activities: Activity[]
}
