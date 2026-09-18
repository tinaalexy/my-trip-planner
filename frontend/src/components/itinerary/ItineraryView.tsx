import DayPanel from './DayPanel'
import TripHeader from './TripHeader'
import ExportButton from './ExportButton'
import type { TripDetail } from '../../types'

function getDays(startDate: string, endDate: string): Date[] {
  const days: Date[] = []
  const start = new Date(startDate + 'T00:00:00')
  const end = new Date(endDate + 'T00:00:00')
  const cur = new Date(start)
  while (cur <= end) {
    days.push(new Date(cur))
    cur.setDate(cur.getDate() + 1)
  }
  return days
}

export default function ItineraryView({ trip }: { trip: TripDetail }) {
  const days = getDays(trip.startDate, trip.endDate)

  return (
    <div>
      <ExportButton trip={trip} />
      <div id="itinerary-print-area" className="bg-white p-4">
        <TripHeader trip={trip} />
        <div className="mt-6">
          {days.map((date, i) => {
            const dayIndex = i + 1
            const activities = trip.activities.filter(a => a.dayIndex === dayIndex)
            return (
              <DayPanel
                key={dayIndex}
                tripId={trip.id}
                dayIndex={dayIndex}
                date={date}
                activities={activities}
              />
            )
          })}
        </div>
      </div>
    </div>
  )
}
