# 01 — MVP Scope (iPad M1/M2/M4)

## Objetivo del MVP
Entregar una app iPad funcional para chat asistido, con inferencia local para tareas rápidas y fallback/handoff para tareas pesadas.

## Incluye (v1)
1. Chat local (historial en dispositivo).
2. Modelo local cuantizado (3B–8B según dispositivo).
3. Ajustes de respuesta (rápida/balanceada).
4. Memoria corta local (sesión actual + últimas conversaciones).
5. Adjuntos simples locales (texto, imagen estática para contexto básico).
6. Modo híbrido: botón para delegar respuesta pesada a backend/Mac.

## No incluye (v1)
1. Ejecución completa de herramientas del ecosistema OpenClaw en iPad.
2. Automatización en background prolongada (limitaciones iPadOS).
3. Multiagente persistente local.
4. Fine-tuning local en dispositivo.

## Criterios de éxito
- Tiempo a primer token aceptable para chat casual.
- UX estable sin crashes por memoria.
- Cambio explícito entre "local" y "delegado".
- Batería/temperatura dentro de niveles razonables en sesiones de 10–20 min.
