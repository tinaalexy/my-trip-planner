import { useState } from 'react'
import { useAddActivity } from '../../hooks/useTripDetail'
import Button from '../ui/Button'

interface Props {
  tripId: string
  dayIndex: number
}

export default function ActivityInput({ tripId, dayIndex }: Props) {
  const [text, setText] = useState('')
  const [error, setError] = useState<string | null>(null)
  const { mutate, isPending } = useAddActivity(tripId)

  function handleAdd() {
    const trimmed = text.trim()
    if (!trimmed) { setError('Required'); return }
    if (trimmed.length > 300) { setError('Max 300 characters'); return }
    setError(null)
    mutate({ dayIndex, text: trimmed }, { onSuccess: () => setText('') })
  }

  return (
    <div className="mt-3 flex flex-col gap-1">
      <div className="flex gap-2">
        <input
          value={text}
          onChange={e => setText(e.target.value)}
          onKeyDown={e => e.key === 'Enter' && handleAdd()}
          placeholder="Add an activity…"
          maxLength={301}
          className={`flex-1 border rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 ${error ? 'border-red-500' : 'border-gray-300'}`}
        />
        <Button onClick={handleAdd} loading={isPending} type="button">Add</Button>
      </div>
      {error && <span className="text-xs text-red-600">{error}</span>}
    </div>
  )
}
