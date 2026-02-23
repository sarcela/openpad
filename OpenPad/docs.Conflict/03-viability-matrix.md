# 03 — Viabilidad por Dispositivo / Modelo (inicial)

> Nota: valores orientativos para decidir pruebas. Se refinan con benchmarks reales.

## Perfiles sugeridos

### iPad M1
- Perfil local recomendado: 3B–7B cuantizado.
- Uso ideal: chat general, resúmenes cortos, drafting.
- Riesgo: throttling en sesiones largas.

### iPad M2
- Perfil local recomendado: 7B cuantizado estable; 8B según runtime.
- Uso ideal: chat general + razonamiento moderado.
- Riesgo: consumo de batería en cargas continuas.

### iPad M4
- Perfil local recomendado: 7B–8B más cómodo, mejor latencia.
- Uso ideal: sesiones más largas locales.
- Riesgo: aún limitado para flujos complejos estilo agente completo.

## Reglas de enrutamiento (propuesta)
- Local si: prompt corto/medio + sin herramientas pesadas.
- Delegado si: contexto largo, tareas multi-step, o necesidad de tools externas.

## Métricas a medir en prototipo
1. Tiempo a primer token.
2. Tokens/segundo sostenidos.
3. Uso de memoria pico.
4. Caída de batería en 15 min.
5. Temperatura percibida y estabilidad.
