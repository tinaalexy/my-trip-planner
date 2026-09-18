import { z } from 'zod'

export const loginSchema = z.object({
  username: z.string().min(1, 'Required'),
  password: z.string().min(1, 'Required'),
})

export const signupSchema = z.object({
  username: z.string()
    .min(3, 'Min 3 characters')
    .max(30, 'Max 30 characters')
    .regex(/^[a-zA-Z0-9_]+$/, 'Letters, digits, and underscores only'),
  password: z.string().min(8, 'Min 8 characters'),
  confirmPassword: z.string(),
}).refine(d => d.password === d.confirmPassword, {
  message: 'Passwords do not match',
  path: ['confirmPassword'],
})

export const tripFormSchema = z.object({
  destination: z.string().min(1, 'Required').max(100, 'Max 100 characters'),
  startDate: z.string().min(1, 'Required'),
  endDate: z.string().min(1, 'Required'),
  tripType: z.string().min(1, 'Please select a trip type'),
}).refine(d => !d.startDate || !d.endDate || d.endDate >= d.startDate, {
  message: 'End date must be on or after start date',
  path: ['endDate'],
})

export const activitySchema = z.object({
  text: z.string().min(1, 'Required').max(300, 'Max 300 characters'),
})
