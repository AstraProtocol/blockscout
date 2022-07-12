import { formatUsdValue } from '../../js/lib/currency'

test('formatUsdValue', () => {
  window.localized = {
    'Less than': 'Less than'
  }
  expect(formatUsdValue(0)).toEqual('$0.000000 ₫')
  expect(formatUsdValue(0.0000001)).toEqual('Less than $0.000001 ₫')
  expect(formatUsdValue(0.123456789)).toEqual('$0.123457 ₫')
  expect(formatUsdValue(0.1234)).toEqual('$0.123400 ₫')
  expect(formatUsdValue(1.23456789)).toEqual('$1.23 ₫')
  expect(formatUsdValue(1.2)).toEqual('$1.20 ₫')
  expect(formatUsdValue(123456.789)).toEqual('$123,457 ₫')
})
