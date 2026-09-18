import { forwardRef } from 'react'
import type { InputHTMLAttributes } from 'react'

interface DateInputProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string
  error?: string
}

const DateInput = forwardRef<HTMLInputElement, DateInputProps>(({ label, error, id, ...props }, ref) => {
  const inputId = id ?? label.toLowerCase().replace(/\s+/g, '-')
  return (
    <div className="flex flex-col gap-1">
      <label htmlFor={inputId} className="text-sm font-medium text-gray-700">{label}</label>
      <input
        type="date"
        id={inputId}
        ref={ref}
        className={`border rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 ${error ? 'border-red-500' : 'border-gray-300'}`}
        {...props}
      />
      {error && <span className="text-xs text-red-600">{error}</span>}
    </div>
  )
})
DateInput.displayName = 'DateInput'
export default DateInput
