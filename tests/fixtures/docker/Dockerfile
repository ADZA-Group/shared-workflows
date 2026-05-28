# Minimal buildable fixture for the reusable-docker-build smoke (also OPA-compliant).
FROM python:3.11-slim
RUN useradd -m appuser
USER appuser
HEALTHCHECK CMD python -c "print('ok')" || exit 1
CMD ["python", "-c", "print('hello from fixture')"]
