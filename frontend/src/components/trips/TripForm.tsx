import { useForm, Controller } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { tripFormSchema } from '../../schemas/auth'
import { useCreateTrip } from '../../hooks/useTrips'
import TextInput from '../ui/TextInput'
import DateInput from '../ui/DateInput'
import TripTypeSelector from './TripTypeSelector'
import Button from '../ui/Button'
import ErrorBanner from '../ui/ErrorBanner'
import { useNavigate } from 'react-router-dom'

type FormData = z.infer<typeof tripFormSchema>

export default function TripForm() {
  const navigate = useNavigate()
  const { mutate, isPending, error } = useCreateTrip()
  const { register, handleSubmit, control, formState: { errors } } = useForm<FormData>({
    resolver: zodResolver(tripFormSchema),
  })

  const apiError = error ? (error as any).response?.data?.detail?.message ?? 'Something went wrong' : null

  return (
    <form onSubmit={handleSubmit(data => mutate(data))} className="flex flex-col gap-5 max-w-lg">
      <ErrorBanner message={apiError} />
      <TextInput label="Destination" error={errors.destination?.message} {...register('destination')} />
      <div className="grid grid-cols-2 gap-4">
        <DateInput label="Start Date" error={errors.startDate?.message} {...register('startDate')} />
        <DateInput label="End Date" error={errors.endDate?.message} {...register('endDate')} />
      </div>
      <Controller
        name="tripType"
        control={control}
        defaultValue=""
        render={({ field }) => (
          <TripTypeSelector value={field.value} onChange={field.onChange} error={errors.tripType?.message} />
        )}
      />
      <div className="flex gap-3">
        <Button type="submit" loading={isPending}>Create Trip</Button>
        <Button type="button" variant="secondary" onClick={() => navigate('/trips')}>Cancel</Button>
      </div>
    </form>
  )
}
