import { TRIP_TYPE_OPTIONS } from '../../lib/tripTypes'

interface Props {
  value: string
  onChange: (value: string) => void
  error?: string
}

export default function TripTypeSelector({ value, onChange, error }: Props) {
  return (
    <div className="flex flex-col gap-1">
      <label className="text-sm font-medium text-gray-700">Trip Type</label>
      <div className="flex flex-wrap gap-2">
        {TRIP_TYPE_OPTIONS.map(opt => (
          <button
            key={opt.value}
            type="button"
            onClick={() => onChange(opt.value)}
            className={`px-4 py-2 rounded border text-sm font-medium transition-colors ${
              value === opt.value
                ? 'bg-blue-600 text-white border-blue-600'
                : 'bg-white text-gray-700 border-gray-300 hover:bg-gray-50'
            }`}
          >
            {opt.label}
          </button>
        ))}
      </div>
      {error && <span className="text-xs text-red-600">{error}</span>}
    </div>
  )
}
