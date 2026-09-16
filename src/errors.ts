import type { FastifyInstance } from 'fastify';

export function registerErrorHandler(app: FastifyInstance): void {
  app.setErrorHandler((error, request, reply) => {
    const details = error !== null && typeof error === 'object' ? error as Record<string, unknown> : {};
    const validation = 'validation' in details;
    const proposedStatus = details.statusCode;
    const status = validation ? 400 : typeof proposedStatus === 'number' && proposedStatus >= 400 && proposedStatus < 500 ? proposedStatus : 500;
    const code = validation ? 'INVALID_PAYLOAD' : status === 413 ? 'PAYLOAD_TOO_LARGE' : status < 500 ? 'INVALID_REQUEST' : 'INTERNAL_ERROR';
    // Do not serialize database errors, rejected values, headers or provider payloads.
    if (status >= 500) request.log.error({ requestId: request.id, code }, 'Request failed');
    void reply.header('Cache-Control', 'no-store').code(status).send({ error: {
      code,
      message: status < 500 ? 'Invalid request.' : 'The request could not be completed.',
      requestId: request.id,
    } });
  });
}
