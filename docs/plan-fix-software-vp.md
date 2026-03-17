# Plan d'action — Suppression du Software Vertex Processing (SVP)

## Contexte

Le skinning des personnages (animation par bones) est entièrement exécuté sur le **CPU** alors que
le vertex shader `VS_WMESH.vsh` contient déjà un chemin GPU complet avec indexed vertex blending.
La pénalité : ~60 % du CPU frame budget gaspillé sur la transformation de vertices, le GPU reste
à moitié vide.

---

## Diagnostic : pourquoi le SVP est forcé

Quatre mécanismes indépendants se cumulent. Tous doivent être corrigés ensemble — en corriger un
seul ne suffit pas.

### Mécanisme 1 — Vertex buffers créés en mémoire système (`D3DUSAGE_SOFTWAREPROCESSING`)

**Fichier :** `TClient/TEngine/Engine Lib/TachyonMesh.cpp`

```cpp
// Lignes 425, 435, 482, 517
m_dwNodeCount > 0 ? D3DUSAGE_SOFTWAREPROCESSING : 0
```

Tout VB/IB d'un mesh skinné est alloué en RAM système avec ce flag. Direct3D refuse d'utiliser
un tel buffer avec un device en hardware VP — c'est un prérequis hard de l'API. Même si on
supprime les autres appels SVP, ce flag seul re-force le SVP au moment du `DrawPrimitive`.

---

### Mécanisme 2 — `SetSoftwareVertexProcessing(TRUE)` inconditionnel au rendu

**Fichier :** `TClient/TEngine/Engine Lib/TachyonMesh.cpp`

```cpp
// Ligne 707 (branche GLOBALVB) et 729 (branche LOCAL)
pDevice->SetSoftwareVertexProcessing(m_dwNodeCount ? TRUE : m_bSoftwareVP);
```

Appel explicite qui bascule le device en SVP pour chaque mesh avec des bones. Cet appel est
fait **avant** chaque `DrawPrimitive`, après la création du device en `D3DCREATE_MIXED_VERTEXPROCESSING`.

Autres appels SVP parasites (non liés au skinning personnages, à traiter séparément) :
- `TachyonSlashSFX.cpp:251` — effets de slash
- `TClientTalkBox.cpp:148` — bulles de dialogue

---

### Mécanisme 3 — Seuil de version shader trop élevé (`vs_3_0` requis, shader est `vs_2_x`)

**Fichier :** `TClient/TEngine/Engine Lib/D3DDevice.cpp`

```cpp
// Lignes 443-446
if( (m_vCAPS.VertexShaderVersion & 0x0000FFFF) < 0x0300 ||
    (m_vCAPS.PixelShaderVersion & 0x0000FFFF) < 0x0300 ||
    m_lVIDEOMEM < 256 )
    m_option.m_bUseSHADER = FALSE;
```

La condition exige **Shader Model 3.0** pour activer les shaders. Or `VS_WMESH.vsh` est compilé
en `vs_2_x` (Shader Model 2.x étendu). Sur un GPU SM2.x (ex. GeForce FX, Radeon 9xxx), les
shaders sont désactivés (`m_bUseSHADER = FALSE`), ce qui force le chemin fixed-function avec
`D3DRS_VERTEXBLEND = D3DVBF_3WEIGHTS` — qui lui-même n'est supporté en hardware que sur très
peu de cartes, donc repasse en SVP.

---

### Mécanisme 4 — Render states du fixed-function pipeline laissés actifs

**Fichier :** `TClient/TEngine/Engine Lib/TachyonObject.cpp`

```cpp
// Ligne 1433
pDevice->m_pDevice->SetRenderState( D3DRS_VERTEXBLEND,
    pPART->m_pMESH->m_dwNodeCount && pANI && pANI->m_pANI
    ? D3DVBF_3WEIGHTS
    : D3DVBF_DISABLE);
```

**Fichier :** `TClient/TEngine/Engine Lib/TachyonMesh.cpp`

```cpp
// Lignes 712, 731
pDevice->SetRenderState( D3DRS_INDEXEDVERTEXBLENDENABLE,
    m_dwNodeCount ? TRUE : FALSE);
```

Quand le chemin programmable est actif (vertex shader chargé), ces render states du pipeline
fixe ne sont pas utilisés par le GPU — mais leur présence active indique que le code a été
conçu pour fonctionner **sans** vertex shader. Laisser `D3DVBF_3WEIGHTS` actif en mode shader
est inoffensif sur certains drivers, problématique sur d'autres. À désactiver proprement.

---

## Pourquoi le GPU path est déjà prêt

`VS_WMESH.vsh` (vs_2_x) effectue un skinning GPU complet :

```asm
if b0                           // b0 = TRUE si skinning actif
    mul r1, v2.zyxw, c0.wwww   // Décoder les 4 indices de bones
    mov r0.xyz, v1.xyz          // Copier les 3 blend weights
    dp3 r0.w, v1.xyz, c0.xxx
    add r0.w, -r0.w, c0.x      // 4ème poids = 1.0 - sum(w0,w1,w2)

    mova a0.x, r1.x             // Adresser la matrice bone 0
    m4x3 r2.xyz, v0, c[a0.x]   // Transform position par bone 0
    m3x3 r3.xyz, v3, c[a0.x]   // Transform normal par bone 0
    mul r2, r2, r0.xxxx         // × weight[0]
    mul r3, r3, r0.xxxx

    mova a0.x, r1.y
    m4x3 r4.xyz, v0, c[a0.x]
    m3x3 r5.xyz, v3, c[a0.x]
    mad r2, r4, r0.yyyy, r2     // Accumule bone 1 × weight[1]
    mad r3, r5, r0.yyyy, r3
    // ... idem bones 2 et 3
else
    m4x3 r2.xyz, v0, c[0]      // Mesh non-skinnée : transform direct
    m3x3 r3.xyz, v3, c[0]
endif
```

Les matrices de bones sont déjà uploadées en constantes VS (`SetVertexShaderConstantF` via
`VC_WORLD`), et `b0` (`VC_SKINNING`) est déjà positionné correctement dans `TachyonObject.cpp:1410`.
Il ne manque rien côté shader — le pipeline GPU existe, il est juste court-circuité par SVP.

---

## Plan d'action

### Étape 1 — Recréer les vertex/index buffers sans `D3DUSAGE_SOFTWAREPROCESSING`

**Fichier :** `TClient/TEngine/Engine Lib/TachyonMesh.cpp`
**Lignes :** 425, 435, 482, 517

**Avant :**
```cpp
DWORD dwUsage = m_dwNodeCount > 0 ? D3DUSAGE_SOFTWAREPROCESSING : 0;
```

**Après :**
```cpp
DWORD dwUsage = D3DUSAGE_WRITEONLY;  // GPU VRAM, lecture par le GPU uniquement
```

> **Note :** `D3DUSAGE_WRITEONLY` est optionnel mais recommandé pour les VB statiques — le driver
> peut les placer en VRAM plutôt qu'en AGP/PCI-e aperture. Pour un VB mis à jour chaque frame
> (morphing), utiliser `D3DUSAGE_DYNAMIC | D3DUSAGE_WRITEONLY` et pool `D3DPOOL_DEFAULT`.
> Le mesh TMF est statique (les vertices ne bougent pas, seules les matrices bones changent) donc
> `D3DUSAGE_WRITEONLY` avec `D3DPOOL_MANAGED` est correct.

**Pool à vérifier :** Si le pool actuel est `D3DPOOL_SYSTEMMEM`, le changer en `D3DPOOL_MANAGED`
(ou `D3DPOOL_DEFAULT` avec gestion du device lost). `D3DPOOL_SYSTEMMEM` force le CPU aussi.

---

### Étape 2 — Supprimer les appels `SetSoftwareVertexProcessing(TRUE)` pour les meshes skinnées

**Fichier :** `TClient/TEngine/Engine Lib/TachyonMesh.cpp`
**Lignes :** 707, 729

**Avant :**
```cpp
pDevice->SetSoftwareVertexProcessing(m_dwNodeCount ? TRUE : m_bSoftwareVP);
```

**Après :**
```cpp
pDevice->SetSoftwareVertexProcessing(FALSE);
```

La condition `m_dwNodeCount` n'a plus de raison d'être : le vertex shader gère le skinning.
`m_bSoftwareVP` devient inutilisé une fois tous les VB migrés vers GPU VRAM.

**Ligne 87 (`EndGlobalDraw`) et 739 :** déjà à `FALSE`, pas de changement.

---

### Étape 3 — Abaisser le seuil de version shader de SM3.0 à SM2.0

**Fichier :** `TClient/TEngine/Engine Lib/D3DDevice.cpp`
**Lignes :** 443-446

**Avant :**
```cpp
if( (m_vCAPS.VertexShaderVersion & 0x0000FFFF) < 0x0300 ||
    (m_vCAPS.PixelShaderVersion  & 0x0000FFFF) < 0x0300 ||
    m_lVIDEOMEM < 256 )
    m_option.m_bUseSHADER = FALSE;
```

**Après :**
```cpp
if( (m_vCAPS.VertexShaderVersion & 0x0000FFFF) < 0x0200 ||
    (m_vCAPS.PixelShaderVersion  & 0x0000FFFF) < 0x0200 ||
    m_lVIDEOMEM < 64 )
    m_option.m_bUseSHADER = FALSE;
```

Justifications :
- `VS_WMESH.vsh` et `PS_SHADER.psh` sont compilés en `vs_2_x` / `ps_2_x` — SM2.0 suffit
- Le seuil VRAM de 256 MB exclut des GPU valides avec 128 MB qui supportent parfaitement SM2.0
  (ex. GeForce 6600 128 MB). 64 MB est un minimum raisonnable pour DX9 avec textures personnages.

---

### Étape 4 — Désactiver les render states fixed-function quand le vertex shader est actif

**Fichier :** `TClient/TEngine/Engine Lib/TachyonObject.cpp`
**Ligne :** 1433

**Avant :**
```cpp
pDevice->m_pDevice->SetRenderState( D3DRS_VERTEXBLEND,
    pPART->m_pMESH->m_dwNodeCount && pANI && pANI->m_pANI
    ? D3DVBF_3WEIGHTS : D3DVBF_DISABLE);
```

**Après :**
```cpp
// En mode shader programmable, D3DRS_VERTEXBLEND est ignoré par le GPU.
// On le désactive explicitement pour éviter tout comportement driver-dépendant.
pDevice->m_pDevice->SetRenderState( D3DRS_VERTEXBLEND, D3DVBF_DISABLE );
```

**Fichier :** `TClient/TEngine/Engine Lib/TachyonMesh.cpp`
**Lignes :** 712, 731

```cpp
// Même logique : désactiver INDEXEDVERTEXBLENDENABLE en mode shader
pDevice->SetRenderState( D3DRS_INDEXEDVERTEXBLENDENABLE, FALSE );
```

> Ces render states sont des vestiges du pipeline fixed-function (avant les vertex shaders
> programmables). Ils n'ont aucun effet quand un vertex shader est actif sur la majorité des
> drivers D3D9, mais les garder actifs pollue l'état du device et peut causer des bugs sur des
> drivers anciens ou des émulateurs (WINE, etc.).

---

### Étape 5 — Vérifier le pool de mémoire des vertex buffers

Lors de la création des VB dans `TachyonMesh.cpp`, vérifier le paramètre `Pool` passé à
`CreateVertexBuffer` / `CreateIndexBuffer` :

| Pool actuel | Problème | Cible |
|---|---|---|
| `D3DPOOL_SYSTEMMEM` | RAM système, accès GPU lent | `D3DPOOL_MANAGED` |
| `D3DPOOL_MANAGED` | OK — driver gère la copie VRAM | Garder |
| `D3DPOOL_DEFAULT` | OK pour GPU, mais device lost à gérer | Garder si déjà présent |

Si `D3DPOOL_SYSTEMMEM` est utilisé, le changer en `D3DPOOL_MANAGED`. Les VB `D3DPOOL_MANAGED`
sont copiés automatiquement en VRAM par le driver et restent valides après device lost (alt-tab).

---

### Étape 6 — Vérifier le nombre de constantes VS disponibles

`VS_WMESH.vsh` accède aux matrices bones via les registres constants avec indexation dynamique
(`mova` + adressage relatif). Le nombre de registres constants utilisés dépend du nombre de bones
transmis :

- `MAX_PIVOT = 255` bones × 3 float4 par ligne de matrice 4×3 = **765 registres**
- SM2.0 garanti : **256 registres constants** (`D3DVS20CAPS.DynamicFlowControlDepth`)
- SM3.0 : **256 registres** (même limite dans la spec, mais certains GPU en exposent plus)

**Action :** Vérifier `D3DCAPS9.MaxVertexShaderConst` au runtime et limiter le nombre de bones
uploadés en conséquence. Si le GPU ne supporte que 256 registres, le maximum est
`floor(256 / 3) = 85 bones` par drawcall, ce qui est largement suffisant pour les personnages 4Story.

Dans `TachyonObject.cpp`, avant l'upload des matrices :

```cpp
// Calculer le max bones uploadables selon les caps GPU
UINT maxBones = min( pDevice->m_vCAPS.MaxVertexShaderConst / 3, MAX_PIVOT );
// Clamp le nombre de bones à uploader
UINT bonesToUpload = min( m_dwNodeCount, maxBones );
```

---

## Résumé des fichiers à modifier

| Fichier | Lignes | Modification |
|---|---|---|
| `TachyonMesh.cpp` | 425, 435, 482, 517 | Remplacer `D3DUSAGE_SOFTWAREPROCESSING` par `D3DUSAGE_WRITEONLY` |
| `TachyonMesh.cpp` | 707, 729 | `SetSoftwareVertexProcessing(FALSE)` inconditionnellement |
| `TachyonMesh.cpp` | 712, 731 | `D3DRS_INDEXEDVERTEXBLENDENABLE = FALSE` |
| `D3DDevice.cpp` | 443-446 | Seuil shader : `< 0x0300` → `< 0x0200`, VRAM `256` → `64` |
| `TachyonObject.cpp` | 1433 | `D3DRS_VERTEXBLEND = D3DVBF_DISABLE` inconditionnellement |
| `TachyonObject.cpp` | ~1410 | (optionnel) Ajouter clamp `maxBones` avant upload constantes |

---

## Gain attendu

| Avant | Après |
|---|---|
| ~4 000 vertices/mesh transformés par le CPU | 0 — tout sur GPU |
| ~60 % CPU frame budget pour skinning (30 chars) | < 5 % (upload matrices uniquement) |
| VB en RAM système : bandwidth PCIe saturée | VB en VRAM : DMA upload 1×/frame au chargement |
| `SetSoftwareVertexProcessing` : flush pipeline D3D à chaque mesh | Aucun flush |
| `D3DCREATE_MIXED_VERTEXPROCESSING` mode SVP actif | Mode HW exclusif pour meshes skinnées |

Gain FPS estimé : **×2 à ×4** sur CPU-bound, selon le nombre de personnages à l'écran.

---

## Risques et précautions

- **Device lost** : Si on passe à `D3DPOOL_DEFAULT`, il faut libérer et recréer tous les VB dans
  `OnDeviceLost` / `OnDeviceReset`. Avec `D3DPOOL_MANAGED` ce n'est pas nécessaire.

- **GPU trop ancien** : Sur un GPU sans SM2.0 (GeForce3 et antérieur), `m_bUseSHADER` sera
  `FALSE` et le code tombera sur le chemin fixed-function. S'assurer que ce fallback continue à
  fonctionner (les render states `D3DVBFx` et SVP sont encore valides pour ce cas).

- **`TachyonSlashSFX.cpp:251`** : Le SVP pour les effets de slash est indépendant. Son vertex
  buffer utilise `WLVERTEX` (pas `WMESHVERTEX`). À migrer séparément — même logique, même fix.

- **`TClientTalkBox.cpp:148`** : SVP pour les bulles de dialogue, format 2D/UI — à analyser
  séparément, probablement pas critique.
