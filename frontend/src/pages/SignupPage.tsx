import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { Link } from 'react-router-dom'
import { signupSchema } from '../schemas/auth'
import { useSignup } from '../hooks/useSignup'
import TextInput from '../components/ui/TextInput'
import Button from '../components/ui/Button'
import ErrorBanner from '../components/ui/ErrorBanner'

type FormData = z.infer<typeof signupSchema>

export default function SignupPage() {
  const { mutate, isPending, error } = useSignup()
  const { register, handleSubmit, formState: { errors } } = useForm<FormData>({
    resolver: zodResolver(signupSchema),
  })
  const apiError = error ? (error as any).response?.data?.detail?.message ?? 'Signup failed' : null

  return (
    <div className="min-h-screen bg-gray-50 flex items-center justify-center px-4">
      <div className="bg-white rounded-lg border border-gray-200 shadow-sm p-8 w-full max-w-sm">
        <h1 className="text-2xl font-bold text-gray-900 mb-6 text-center">Create Account</h1>
        <ErrorBanner message={apiError} />
        <form onSubmit={handleSubmit(data => mutate({ username: data.username, password: data.password }))} className="flex flex-col gap-4">
          <TextInput label="Username" error={errors.username?.message} autoComplete="username" {...register('username')} />
          <TextInput label="Password" type="password" error={errors.password?.message} autoComplete="new-password" {...register('password')} />
          <TextInput label="Confirm Password" type="password" error={errors.confirmPassword?.message} autoComplete="new-password" {...register('confirmPassword')} />
          <Button type="submit" loading={isPending} className="w-full mt-2">Sign Up</Button>
        </form>
        <p className="text-sm text-center mt-4 text-gray-500">
          Already have an account?{' '}
          <Link to="/login" className="text-blue-600 hover:underline">Log in</Link>
        </p>
      </div>
    </div>
  )
}
