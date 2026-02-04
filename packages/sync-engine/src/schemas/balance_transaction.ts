import type { EntitySchema } from './types'

export const balanceTransactionSchema: EntitySchema = {
  properties: [
    'id',
    'object',
    'amount',
    'available_on',
    'created',
    'currency',
    'description',
    'exchange_rate',
    'fee',
    'fee_details',
    'net',
    'reporting_category',
    'source',
    'status',
    'type',
  ],
} as const
