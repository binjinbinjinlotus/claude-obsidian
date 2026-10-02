/**
 * Errors thrown by engine actions. The server maps `code` to HTTP status:
 * not_found→404, invalid_request→400, invalid_state/busy/no_vault→409.
 */
export type CoreErrorCode = 'not_found' | 'invalid_request' | 'invalid_state' | 'busy' | 'no_vault';

export class CoreError extends Error {
  constructor(
    readonly code: CoreErrorCode,
    message: string,
  ) {
    super(message);
    this.name = 'CoreError';
  }
}
