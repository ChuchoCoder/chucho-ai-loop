# Contrato de Chucho AI Loop

Este contrato es la fuente de verdad para las dos interfaces de agente. El instalador copia el control-plane a `.ai-loop/core.ps1`; las interfaces llaman ese archivo y consumen su salida JSON.

## Configuración

`.ai-loop/config.json` tiene `schemaVersion: 1` y estos campos:

| Campo | Significado |
| --- | --- |
| `repository` | Repositorio GitHub como `owner/repository`. |
| `baseBranch` | Rama desde la cual se crean los worktrees. |
| `assistants` | Uno o ambos: `Claude`, `ChatGPT`. |
| `testCommands` | Comandos que el desarrollo ejecuta antes de pedir revisión. |
| `activeLimit` | Issues activos a la vez. La v1 usa `1`. |
| `pendingLimit` | Máximo de issues abiertos en espera de CI o decisión humana. Por defecto `3`. |
| `maxReviewRounds` | Máximo de vueltas `en-review` ↔ `corrigiendo`. |
| `merge.mode` | `manual` o `guarded`; el valor inicial es `manual`. |
| `merge.requiredChecks` | Checks de GitHub requeridos cuando el modo es `guarded`. |

Los valores de configuración no guardan tokens. La sesión local de `gh` es la identidad que opera GitHub.

## Control-plane

Toda mutación de control-plane pasa por:

```powershell
pwsh .ai-loop/core.ps1 -Command <comando> -Root <checkout-dedicado> [argumentos]
```

Comandos públicos:

| Comando | Uso |
| --- | --- |
| `Doctor` | Verifica PowerShell 7, Git, `gh`, autenticación, configuración y checkout. |
| `Status` | Lee el snapshot sin mutarlo: `Snapshot.Active`, `Snapshot.Candidates`, `Snapshot.Ambiguous`, capacidad y lock. Puede informar `ClosedWithLoopState` cuando haya limpieza pendiente. |
| `ScheduleGate` | Decide si esa ejecución y asistente pueden trabajar en esta hora UTC. |
| `AcquireLock` / `ReleaseLock` | Gestionan el lock compartido para una mutación. |
| `SweepClosed` | Libera el estado local de issues que GitHub ya cerró. |
| `Transition` | Relee GitHub y cambia el estado de un issue válido. |
| `PrepareSlot` | Prepara el worktree de un issue que ya está en `en-dev`. |
| `InspectPullRequest` | Comprueba que el PR corresponde al issue y a su trabajo. |
| `ValidateMerge` | Con el lock del runner, evalúa los gates de `guarded` y ejecuta `testCommands` en el worktree si las demás señales están verdes. No cambia GitHub, pero esos comandos pueden generar archivos. |
| `Merge` | Hace el squash protegido y confirma el resultado. |

Los resultados válidos salen como JSON. Por ejemplo, `AcquireLock -Apply` puede devolver `Acquired: false` y `ValidateMerge` puede devolver `CanMerge: false`; ambos son resultados que el adaptador reporta y no fuerza. Las precondiciones, transiciones inválidas y fallos de GitHub terminan con código no cero y diagnóstico por stderr. `Status` no selecciona un issue: el adaptador usa el único elemento de `Snapshot.Active`, o el primer elemento de `Snapshot.Candidates` cuando no hay activo.

Argumentos compartidos: `-Root`, `-Issue`, `-FromState`, `-ToState`, `-Token`, `-Assistant`, `-Pr`, `-ExpectedHeadSha` y `-Apply`. Cada comando exige sólo los que necesita. `-Apply` habilita los cambios de estado, slots y merge; `ValidateMerge` ejecuta los tests configurados aun sin `-Apply`.

El checkout dedicado identifica su ejecución con `.ai-loop/state/runner.json`; el control-plane requiere ese archivo para mutaciones. Los locks y slots viven en `.ai-loop/state/`, que no se versiona. Cada tick ejecuta `Doctor`, `ScheduleGate` y luego `AcquireLock -Apply`; si recibe token, lo conserva hasta `ReleaseLock -Token <token> -Apply` en un `finally`. Con el lock, consulta `Status`, aplica `SweepClosed -Issue <issue> -Token <token> -Apply` para cada `ClosedWithLoopState`, y vuelve a consultar `Status`. El lock es obligatorio antes de cambiar estado, preparar un slot o mergear. Si el lock no se puede verificar, una llamada falla por stderr y el adaptador lo reporta. Los adaptadores no editan labels del loop, slots, locks ni merges directamente.

El control-plane no actualiza su checkout. Después de publicar en la rama base una actualización del loop, ejecutá `install.ps1 -TargetPath <repo> -BootstrapRunner` desde la distribución para hacer fast-forward del runner dedicado.

## Elegibilidad y estados

Un issue entra con exactamente una prioridad `priority/P0`, `priority/P1`, `priority/P2` o `priority/P3`. `blocked` e `icebox` lo excluyen. Con `activeLimit: 1`, el control-plane sólo deja un issue en progreso. `espera-merge`, `espera-auto` y `necesita-humano` no ocupan ese lugar, pero juntos tienen el techo `pendingLimit`.

Estados admitidos:

```mermaid
stateDiagram-v2
    [*] --> planificando
    planificando --> en-dev
    en-dev --> en-review
    en-review --> corrigiendo
    corrigiendo --> en-review
    en-review --> review-final
    review-final --> espera-merge
    en-dev --> espera-auto
    en-review --> espera-auto
    review-final --> espera-auto
    espera-auto --> en-dev
    espera-auto --> en-review
    espera-auto --> review-final
    planificando --> necesita-humano
    en-dev --> necesita-humano
    en-review --> necesita-humano
    review-final --> necesita-humano
```

`espera-auto` significa que falta una señal que el loop puede volver a consultar, como CI o una respuesta de revisión. `necesita-humano` representa una decisión, ambigüedad o inconsistencia que no se resuelve en automático. `espera-merge` deja un PR listo para aprobación y merge humano. Cuando GitHub cierra ese issue, `SweepClosed` libera su estado administrativo; no se sale de `espera-merge` mediante `Transition`.

Antes de entrar en `espera-auto` o `necesita-humano`, el adaptador deja en un comentario del issue la señal o decisión pendiente y el estado desde el que llegó. `Status.Snapshot.Pending` permite reconsultar esas esperas. Una espera automática vuelve al estado indicado sólo cuando se comprueba que la señal cambió; una decisión humana vuelve cuando la respuesta queda documentada en el issue. Si no hay cambio, se conserva la espera y puede atenderse otro candidato dentro del techo `pendingLimit`.

El control-plane rechaza una transición que no parte del estado recién releído, una combinación ambigua de labels, un PR no asociado, un worktree sucio o una condición de lock sin verificar. El diagnóstico queda junto al issue para que una persona pueda decidir cómo seguir.

## Revisión y merge

Cada devolución de `en-review` a `corrigiendo` deja primero un comentario en el issue con el marcador exacto `<!-- ai-loop:review-round:N sha=<40hex> -->`, donde `N` es la próxima vuelta y el SHA es el head de 40 caracteres que se revisó. El comentario explica las correcciones pedidas. El control-plane exige marcadores correlativos, el SHA actual y `N` dentro de `maxReviewRounds`. Para volver a `en-review`, el PR necesita un nuevo SHA. Agotado el límite, se pasa a `review-final` con la evidencia pendiente.

En `manual`, la etapa final termina en `espera-merge`: el PR necesita aprobación y merge humano.

`PrepareSlot` crea la rama `ai-loop/issue-N` para el issue `N`. El PR sale de esa rama, apunta a `baseBranch` y su body contiene `Closes #N`; después de cada push, el HEAD del slot debe coincidir con el SHA del PR. Un PR desde un fork o con otro HEAD no puede avanzar.

En `guarded`, el administrador configura en GitHub los checks de `merge.requiredChecks`. La revisión final transiciona primero a `espera-merge` y publica el marcador exacto `<!-- ai-loop:merge-authorized issue=N pr=P sha=SHA -->` en un comentario del PR. `ValidateMerge` exige ese estado, vuelve a ejecutar `testCommands` en el worktree del issue, comprueba que el SHA y el árbol sigan iguales, y exige CI verde y cero threads abiertos. `Merge` repite esa validación, usa squash con `gh pr merge --match-head-commit` y confirma luego que GitHub marcó el PR como mergeado. Cualquier señal faltante deja el issue para decisión humana.

## Dos asistentes

Cada tarea se puede programar por hora. Si están Claude y ChatGPT, ambas se ejecutan pero `ScheduleGate` alterna por hora UTC cuál continúa; la otra devuelve una salida sin mutar el repositorio. El tick efectivo procesa una sola etapa: planificación, desarrollo, revisión, corrección o revisión final. Esto evita que dos asistentes hagan trabajo efectivo sobre el mismo issue durante la misma ventana.
