# 04 — Plan de Ejecución (Semana 1)

Objetivo de la semana: llegar a un prototipo funcional de app iPad con chat básico, ruta local simulada/real mínima y ruta delegada definida.

## Día 1 — Setup base del proyecto
**Entregables**
- Proyecto iPad (SwiftUI) creado.
- Estructura inicial de módulos (`ChatUI`, `ConversationStore`, `InferenceEngine`, `DelegateClient`, `PolicyRouter`).
- Documento corto de decisiones técnicas iniciales.

**Checklist**
- [ ] Crear repo/app base
- [ ] Configurar targets y build settings
- [ ] Definir interfaces/protocolos

---

## Día 2 — Chat UI + estado local
**Entregables**
- Pantalla de chat funcional (input, lista de mensajes, estados de carga).
- Persistencia mínima local para conversaciones recientes.

**Checklist**
- [ ] Vista chat con streaming simulado
- [ ] Guardado/carga local de historial
- [ ] Manejo de errores UX básico

---

## Día 3 — Motor local (PoC)
**Entregables**
- Integración inicial de runtime local (PoC) o mock con interfaz real.
- Primera respuesta local end-to-end.

**Checklist**
- [ ] Implementar `InferenceEngine` v0
- [ ] Cargar modelo pequeño o mock equivalente
- [ ] Medir tiempo a primera respuesta

---

## Día 4 — Ruta delegada (handoff)
**Entregables**
- `DelegateClient` con endpoint configurable.
- Botón/selector para forzar respuesta delegada.

**Checklist**
- [ ] Conexión segura al backend/Mac
- [ ] UX clara de "Local" vs "Delegado"
- [ ] Reintento y timeout básico

---

## Día 5 — Router de políticas
**Entregables**
- Reglas básicas para decidir local vs delegado automáticamente.
- Logs de decisión para depuración.

**Checklist**
- [ ] Heurísticas por tamaño de prompt/contexto
- [ ] Fallback automático a delegado ante error local
- [ ] Métricas simples por ruta

---

## Día 6 — Medición en dispositivo (M1/M2/M4)
**Entregables**
- Mini benchmark interno (TTFT, fluidez, estabilidad).
- Ajustes de parámetros iniciales por perfil de iPad.

**Checklist**
- [ ] Prueba de 10–15 min por ruta
- [ ] Observación de batería/temperatura
- [ ] Ajuste de límites para evitar throttling

---

## Día 7 — Cierre de sprint + backlog
**Entregables**
- Demo interna funcional.
- Lista priorizada para Semana 2.
- Decisión: runtime final candidato para v1.

**Checklist**
- [ ] Demo script (3 escenarios)
- [ ] Riesgos abiertos documentados
- [ ] Próximos pasos aprobados

---

## Definición de "hecho" de Semana 1
1. App abre y mantiene conversaciones locales.
2. Puede responder por ruta local (aunque sea limitada) y ruta delegada.
3. Existe criterio automático básico para enrutar.
4. Se tienen primeras métricas reales en al menos un iPad M-series.
