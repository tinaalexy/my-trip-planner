import { tripTypeLabel } from '../../lib/tripTypes'
import type { TripDetail } from '../../types'

function formatDate(dateStr: string) {
  return new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'long', year: 'numeric' })
    .format(new Date(dateStr + 'T00:00:00'))
}

export default function TripHeader({ trip }: { trip: TripDetail }) {
  return (
    <div className="mb-4">
      <h1 className="text-3xl font-bold text-gray-900">{trip.destination}</h1>
      <p className="text-gray-500 mt-1">
        {formatDate(trip.startDate)} – {formatDate(trip.endDate)}
        <span className="ml-3 text-xs font-semibold bg-blue-50 text-blue-700 border border-blue-200 rounded-full px-3 py-1">
          {tripTypeLabel(trip.tripType)}
        </span>
      </p>
    </div>
  )
}
