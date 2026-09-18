import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { Link, useSearchParams } from 'react-router-dom'
import { loginSchema } from '../schemas/auth'
import { useLogin } from '../hooks/useLogin'
import TextInput from '../components/ui/TextInput'
import Button from '../components/ui/Button'
import ErrorBanner from '../components/ui/ErrorBanner'

type FormData = z.infer<typeof loginSchema>

export default function LoginPage() {
  const [searchParams] = useSearchParams()
  const expired = searchParams.get('expired') === '1'
  const { mutate, isPending, error } = useLogin()
  const { register, handleSubmit, formState: { errors } } = useForm<FormData>({
    resolver: zodResolver(loginSchema),
  })
  const apiError = error ? (error as any).response?.data?.detail?.message ?? 'Login failed' : null

  return (
    <div className="min-h-screen bg-gray-50 flex items-center justify-center px-4">
      <div className="bg-white rounded-lg border border-gray-200 shadow-sm p-8 w-full max-w-sm">
        <h1 className="text-2xl font-bold text-gray-900 mb-6 text-center">My Trip Planner</h1>
        {expired && (
          <div className="bg-yellow-50 border border-yellow-300 text-yellow-800 rounded px-4 py-3 text-sm mb-4">
            Your session has expired, please log in again
          </div>
        )}
        <ErrorBanner message={apiError} />
        <form onSubmit={handleSubmit(data => mutate(data))} className="flex flex-col gap-4">
          <TextInput label="Username" error={errors.username?.message} autoComplete="username" {...register('username')} />
          <TextInput label="Password" type="password" error={errors.password?.message} autoComplete="current-password" {...register('password')} />
          <Button type="submit" loading={isPending} className="w-full mt-2">Log In</Button>
        </form>
        <p className="text-sm text-center mt-4 text-gray-500">
          Don't have an account?{' '}
          <Link to="/signup" className="text-blue-600 hover:underline">Sign up</Link>
        </p>
      </div>
    </div>
  )
}
