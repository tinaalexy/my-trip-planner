import ActivityItem from './ActivityItem'
import ActivityInput from './ActivityInput'
import type { Activity } from '../../types'

interface Props {
  tripId: string
  dayIndex: number
  date: Date
  activities: Activity[]
}

function formatDayHeading(date: Date, dayIndex: number) {
  const dateStr = new Intl.DateTimeFormat('en-GB', {
    weekday: 'long', day: 'numeric', month: 'long', year: 'numeric'
  }).format(date)
  return `Day ${dayIndex} – ${dateStr}`
}

export default function DayPanel({ tripId, dayIndex, date, activities }: Props) {
  return (
    <div className="bg-white border border-gray-200 rounded-lg mb-4 overflow-hidden">
      <div className="bg-gray-50 border-b border-gray-200 px-4 py-3">
        <h3 className="font-semibold text-gray-800 text-sm">{formatDayHeading(date, dayIndex)}</h3>
      </div>
      <div className="px-4 py-3">
        {activities.length === 0 && (
          <p className="text-sm text-gray-400 italic mb-2">No activities yet</p>
        )}
        {activities.map(a => (
          <ActivityItem key={a.id} tripId={tripId} activity={a} />
        ))}
        <ActivityInput tripId={tripId} dayIndex={dayIndex} />
      </div>
    </div>
  )
}
