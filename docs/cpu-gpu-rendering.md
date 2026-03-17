# CPU vs GPU — Répartition du rendu des personnages

> Basé sur l'analyse du code source `Z:\TClient` (moteur Tachyon Engine, DirectX 9 Mixed Vertex Processing)

---

## Table des matières

1. [Vue d'ensemble](#1-vue-densemble)
2. [Travail CPU](#2-travail-cpu)
3. [Travail GPU](#3-travail-gpu)
4. [Transfert CPU → GPU](#4-transfert-cpu--gpu)
5. [Vertex processing : logiciel vs matériel](#5-vertex-processing--logiciel-vs-matériel)
6. [Shaders](#6-shaders)
7. [Flux de données complet](#7-flux-de-données-complet)
8. [Synthèse](#8-synthèse)

---

## 1. Vue d'ensemble

Le pipeline est **majoritairement CPU**. Seules la déformation des vertices par les os (skinning), l'éclairage Gouraud et le shading des pixels sont délégués au GPU. Tout le reste — interpolation des keyframes, hiérarchie des os, blending d'animations, sélection du LOD, frustum culling — est calculé sur le CPU chaque frame.

```
┌─────────────────────────────────────────────────────┐
│                       CPU                           │
│  Interpolation keyframes  (SLERP/Lerp par os)       │
│  Hiérarchie squelettique  (M_parent × M_enfant)     │
│  Blending d'animations    (SLERP quaternions)       │
│  Frustum culling          (sphère vs 5 plans)       │
│  Sélection LOD            (distance caméra)         │
│  Matrice monde + pivot    (m_pBone[0..N])           │
└────────────────────┬────────────────────────────────┘
                     │ SetVertexShaderConstantF()
                     │ 3 × (N+1) × 4 floats / personnage / frame
                     ▼
┌─────────────────────────────────────────────────────┐
│                       GPU                           │
│  Vertex shader   : skinning 4 os, éclairage Gouraud │
│  Pixel shader    : specular Phong, blend textures   │
│  Rasterisation   : interpolation, z-test, write     │
└─────────────────────────────────────────────────────┘
```

---

## 2. Travail CPU

### 2.1 Interpolation des keyframes
**Fichier :** `TachyonAnimation.cpp`, lignes 905–998
**Fréquence :** chaque frame, pour chaque os de chaque personnage

Trois fonctions indépendantes :

| Fonction | Méthode | Composante |
|---|---|---|
| `CalcPositionVector()` | Lerp linéaire | Position (X, Y, Z) |
| `CalcRotation()` | **SLERP quaternion** | Rotation |
| `CalcScale()` | Lerp linéaire | Scale (X, Y, Z) |

```cpp
// CalcRotation — TachyonAnimation.cpp ~ligne 957
CTMath::MaxSlerp(pKey[i-1].m_vKeyQuat, pKey[i].m_vKeyQuat, fTime);
// fTime = fraction entre les deux keyframes

// CalcScale — ~ligne 987
D3DXVec3Lerp(&vRESULT,
    &pKey[i-1].m_vKeyScale,
    &pKey[i].m_vKeyScale,
    fTime);
```

### 2.2 Hiérarchie squelettique
**Fichier :** `TachyonAnimation.cpp`, lignes 702–897 — `GetFrameMatrix()`
**Fréquence :** chaque frame, optimisé par cache

Pour chaque os dans l'arbre (racine → feuilles) :

```cpp
// ~ligne 789 — multiplication parent × enfant dans l'espace monde
pResult[m_pTREE[i].m_bINDEX + 1] =
    animation_result
    * vRESULT[m_pTREE[i].m_bINDEX + 1]
    * vTSCALE[...]
    * vRESULT[bRootID]
    * vWorld;     // ← position mondiale du personnage

// Scale accumulé le long de la hiérarchie
vTSCALE[m_pTREE[i].m_bINDEX + 1] =
    vTSCALE[m_pTREE[i].m_bParentPOS]
    * vTSCALE[m_pTREE[i].m_bINDEX + 1];
```

**Résultat :** tableau `m_pBone[0..MaxPivot]` — une matrice 4×4 par os, dans l'espace monde.

**Cache d'optimisation** (`TachyonObject.cpp`, lignes 1164–1170) :

```cpp
BYTE bNeedCompute =
    (m_fActTime    != m_fActTimeLast)    ||
    (m_dwBlendTick != m_dwBlendTickLast) ||
    (m_vPosition._41 != m_fPosLastX)    ||
    (m_vPosition._42 != m_fPosLastY)    ||
    (m_vPosition._43 != m_fPosLastZ);

if (bNeedCompute)
    GetFrameMatrix(...);   // coûteux — skippé si rien n'a changé
```

### 2.3 Blending d'animations
**Fichier :** `TachyonAnimation.cpp`, lignes 623–655 et `TachyonObject.cpp`, lignes 523–568
**Fréquence :** uniquement pendant les transitions (`m_dwBlendTick < m_dwBlend`)

```cpp
// GetBlendKEY — extraction du quaternion depuis les matrices d'animation précédente
pBlendKEY[...] = vINV * GetReviseROT(...) * vNEXT;

// Dans GetFrameMatrix avec blending
D3DXQuaternionSlerp(&vROT, &vIDENTITY, &pBlendKEY[...], fBlendTime);
D3DXVec3Lerp(&vPOS, &vPREV, &vNEXT, fBlendTime);
vBLEND = pBlend[...] * vBLEND;
```

### 2.4 Frustum culling
**Fichier :** `TachyonObject.cpp`, lignes 1951–2030 — `OBJInRect()`

Construction d'un frustum à 5 plans depuis un rectangle écran, puis test de la sphère englobante du personnage :

```cpp
// 4 rayons depuis la caméra vers les coins du rectangle
D3DXVECTOR3 vDIR[4] = {
    pCamera->GetRayDirection(rect.left,  rect.top),
    pCamera->GetRayDirection(rect.right, rect.top),
    pCamera->GetRayDirection(rect.right, rect.bottom),
    pCamera->GetRayDirection(rect.left,  rect.bottom)
};

// 4 plans latéraux + 1 plan near
D3DXPlaneFromPoints(&vPLANE[i], &camPos,
    &(camPos + vDIR[i]), &(camPos + vDIR[(i+1)%4]));
D3DXPlaneFromPointNormal(&vPLANE[4],
    &pCamera->m_vPosition,
    &(pCamera->m_vPosition - pCamera->m_vTarget));

// Test sphère englobante (rayon dans TachyonMesh::m_fRadius)
```

### 2.5 Sélection du LOD
**Fichier :** `TachyonMesh.cpp`, lignes 828–838

```cpp
int CTachyonMesh::GetLevel(FLOAT fDist) {
    int nResult = 0;
    for (int i = 0; i < nCount; i++)
        if (fDist > m_fLevelFactor * m_vDist[i])
            nResult = i + 1;
    return min(nResult, nCount);
}
```

Chaque niveau de LOD correspond à un index buffer différent (moins de triangles). La sélection est purement CPU, basée sur la distance caméra–personnage calculée dans `Render()`.

---

## 3. Travail GPU

### 3.1 Vertex shader — skinning 4 os
**Fichier :** `Z:\TClient\TClient\res\VS_WMESH.vsh`

Pour chaque vertex, le GPU exécute un vertex shader assembleur (`vs_1_1`) qui réalise le skinning par vertex blending indexé sur 4 os :

```asm
; Entrées
; v0 = position xyz
; v1 = blend weights (w1, w2, w3) — le 4e est déduit
; v2 = blend indices (b0, b1, b2, b3) encodés en UBYTE4
; v3 = normale xyz

; Conversion UBYTE4 → float (ligne 51)
mul r1, v2.zyxw, c0.wwww

; Calcul du 4e poids (lignes 54-57)
dp3 r0.w, v1.xyz, c0.xxx   ; somme des 3 premiers poids
add r0.w, -r0.w, c0.x      ; w4 = 1.0 - (w1+w2+w3)

; Skinning : 4 transformations pondérées (lignes 65-97)
mova a0.x, r1.x
m4x3 r2.xyz, v0, c397[a0.x]  ; pos  × matrice[os1]
m3x3 r3.xyz, v3, c397[a0.x]  ; norm × matrice[os1]
mul  r2, r2, r0.xxxx          ; × w1

mova a0.x, r1.y
m4x3 r4.xyz, v0, c397[a0.x]  ; pos  × matrice[os2]
m3x3 r5.xyz, v3, c397[a0.x]  ; norm × matrice[os2]
mad  r2, r4, r0.yyyy, r2      ; r2 += résultat × w2

; ... idem pour os3 et os4

; Position finale dans r2, normale dans r3
```

`c397` est le banc de registres constants contenant toutes les matrices d'os transposées, chargées par le CPU via `SetVertexShaderConstantF`.

### 3.2 Vertex shader — éclairage Gouraud
**Fichier :** `VS_WMESH.vsh`, lignes 105–157

Après le skinning, le même vertex shader calcule la couleur diffuse par vertex :

```asm
mov r4, c2          ; ambiant de départ

loop aL, i0         ; boucle sur les lumières actives
    ; Lumières directionnelles et ponctuelles
    ; dot(normale, direction_lumière) → intensité diffuse
    ; Accumulation dans r4
endloop

; UV output
m3x2 oT0.xy, r5, c3    ; UVs stage 0
m3x2 oT2.xy, r5, c5    ; UVs stage 1
```

Registres constants lumières (chargés par CPU) :
- `c11[128]` — directions des lumières
- `c141[128]` — ambiant des lumières
- `c269[128]` — diffus des lumières

### 3.3 Pixel shader — specular et textures
**Fichier :** `Z:\TClient\TClient\res\PS_SHADER.psh`

```asm
ps_2_0

; Échantillonnage des textures
texld_pp r0, t0, s0   ; texture diffuse
texld_pp r1, t2, s1   ; texture de détail / spéculaire

; Specular Phong (lignes 42–63)
nrm_pp r5.xyz, t3             ; normaliser direction caméra
add_pp r5.xyz, r5, -t5        ; vecteur H (half vector)
nrm_pp r3.xyz, r5
dp3_pp r3.x,  r3, r4          ; dot(H, normale)
pow_pp r3.x,  r3.x, c1.z      ; exposant spéculaire (Phong)

; Composition finale (lignes 67–68)
mad_pp r0, r1.yyyy, r3.xxxx, r0   ; diffuse + specular
mul_pp r0, r0, v0                  ; × couleur vertex (Gouraud du VS)
```

---

## 4. Transfert CPU → GPU

### 4.1 Matrices d'os (dominant)
**Fichier :** `TachyonObject.cpp`, lignes 1189–1205 — `ApplyMatrix()`

**Mode shader (m_bUseSHADER = TRUE) :**

```cpp
// Transposition (row-major → column-major pour HLSL/ASM)
D3DXMatrixTranspose((LPD3DXMATRIX) vWORLD, m_pBone);
for (int i = 0; i < nodeCount; i++)
    D3DXMatrixTranspose((LPD3DXMATRIX) &vWORLD[12*(i+1)],
                        &(pInit[i] * m_pBone[i+1]));

pDevice->m_pDevice->SetVertexShaderConstantF(
    pDevice->m_vConstantVS[VC_WORLD],   // registre c397
    vWORLD,
    3 * (nodeCount + 1));               // 3 vec4 par matrice 4×3
```

**Quantité transférée :**
- 1 matrice = 3 rangées × 4 floats = 12 floats
- N os + 1 racine → **(N+1) × 12 floats** par personnage par frame
- Exemple : 20 os → 252 floats → 1 008 octets

**Mode fixed-function (pas de shader) :**

```cpp
pDevice->m_pDevice->SetTransform(D3DTS_WORLDMATRIX(0), &m_pBone[0]);
for (int i = 0; i < nodeCount; i++)
    pDevice->m_pDevice->SetTransform(D3DTS_WORLDMATRIX(i+1),
                                     &(pInit[i] * m_pBone[i+1]));
```

**Fréquence :** une fois par personnage par frame — sauf si le cache d'optimisation a déterminé qu'aucune valeur n'a changé.

### 4.2 Buffers de vertices (statiques)
**Fichier :** `TachyonMesh.cpp`, lignes 414–489

Les vertex buffers sont créés **une seule fois** au chargement du mesh :

```cpp
pDevice->CreateVertexBuffer(
    vertexCount * sizeof(WMESHVERTEX),
    m_dwNodeCount ? D3DUSAGE_SOFTWAREPROCESSING : 0,
    T3DFVF_WMESHVERTEX,
    D3DPOOL_MANAGED,
    &m_pVB, NULL);

m_pVB->Lock(0, 0, &pBUF, 0);
memcpy(pBUF, m_pDATA->m_pVB, size);   // copie unique
m_pVB->Unlock();
```

Ils ne sont **jamais** verrouillés/modifiés par frame. Les positions des vertices restent en bind pose — c'est le GPU (ou le software VP) qui les déplace via le skinning.

### 4.3 Constantes de transformation UV
**Fichier :** `TachyonObject.cpp`, lignes 1250–1253

```cpp
// Si les UVs sont animés (effets, dégâts...)
D3DXMatrixTranspose((LPD3DXMATRIX) vTEX, &vUV);
pDevice->m_pDevice->SetVertexShaderConstantF(
    VC_TEXTRAN0,   // c3
    vTEX, 2);      // 8 floats — matrix UV stage 0
```

---

## 5. Vertex processing : logiciel vs matériel

### 5.1 Initialisation du device
**Fichier :** `D3DDevice.cpp`, lignes 413–416

```cpp
if (m_vCAPS.DevCaps & D3DDEVCAPS_HWTRANSFORMANDLIGHT)
    dwBehavior |= D3DCREATE_MIXED_VERTEXPROCESSING;   // GPU préféré
else
    dwBehavior |= D3DCREATE_SOFTWARE_VERTEXPROCESSING; // fallback CPU
```

Le device est créé en mode **MIXED** sur tout matériel moderne.

### 5.2 Basculement par mesh
**Fichier :** `TachyonMesh.cpp`, lignes 707, 729

```cpp
pDevice->SetSoftwareVertexProcessing(
    m_dwNodeCount ? TRUE : m_bSoftwareVP);
```

| Condition | Mode | Raison |
|---|---|---|
| Mesh avec os (`m_dwNodeCount > 0`) | **Logiciel forcé** | D3D9 : `D3DVBF_3WEIGHTS` indexé nécessite le software VP |
| Mesh sans os | Matériel (défaut) | Pas de vertex blending, le GPU peut tout faire |

**Conséquence importante :** les personnages animés passent par le **software vertex processing** de Direct3D 9, ce qui signifie que la transformation des vertices (skinning) s'exécute sur le CPU via le pilote D3D, pas sur le GPU. Le GPU reçoit des vertices déjà transformés.

```cpp
// États D3D associés (TachyonMesh.cpp ~ligne 666)
pDevice->SetRenderState(D3DRS_VERTEXBLEND,
    m_dwNodeCount ? D3DVBF_3WEIGHTS : D3DVBF_DISABLE);
pDevice->SetRenderState(D3DRS_INDEXEDVERTEXBLENDENABLE,
    m_dwNodeCount ? TRUE : FALSE);
```

---

## 6. Shaders

| Fichier | Type | Utilisé quand | Rôle |
|---|---|---|---|
| `VS_WMESH.vsh` | Vertex shader assembleur `vs_1_1` | `m_bUseSHADER = TRUE` + bones | Skinning 4 os + Gouraud |
| `VS_MESH.vsh` | Vertex shader assembleur `vs_1_1` | `m_bUseSHADER = TRUE` + no bones | Transform simple + Gouraud |
| `PS_SHADER.psh` | Pixel shader assembleur `ps_2_0` | `m_bUseSHADER = TRUE` | Specular Phong + blend textures |
| *(fixed-function)* | — | `m_bUseSHADER = FALSE` | États D3D uniquement |

> **Note :** les shaders existent mais ne sont activés que si `m_bUseSHADER = TRUE`. En mode fixed-function, tout repose sur les états `D3DRS_*` et `D3DTS_WORLDMATRIX`.

---

## 7. Flux de données complet

```
╔══════════════════════════════════════════════════════════╗
║  CPU — par frame, par personnage                         ║
╠══════════════════════════════════════════════════════════╣
║                                                          ║
║  1. CalcTick()          [TachyonObject.cpp:944]          ║
║     ├─ m_fActTime += deltaTime                           ║
║     └─ m_dwBlendTick += deltaTime (si blending actif)   ║
║                                                          ║
║  2. GetFrameMatrix()    [TachyonAnimation.cpp:702]       ║
║     ├─ CalcPositionVector()  Lerp  par os                ║
║     ├─ CalcRotation()        SLERP par os                ║
║     ├─ CalcScale()           Lerp  par os                ║
║     └─ M_parent × M_enfant  → m_pBone[0..N]             ║
║         (skippé si cache valide)                         ║
║                                                          ║
║  3. ApplyMatrix()        [TachyonObject.cpp:1146]        ║
║     ├─ D3DXMatrixTranspose(m_pBone)                      ║
║     └─ ──────────────────────────────────────────────►  ║
║         SetVertexShaderConstantF(c397, bones, 3*(N+1))  ║
║         ou SetTransform(D3DTS_WORLDMATRIX(i))            ║
║                                                          ║
║  4. SetSoftwareVertexProcessing(TRUE)   ← si bones       ║
║  5. SetRenderState(D3DRS_VERTEXBLEND, D3DVBF_3WEIGHTS)  ║
║  6. DrawIndexedPrimitive()                               ║
║                                                          ║
╚══════════╦═══════════════════════════════════════════════╝
           ║ Vertices en bind pose (VB statique)
           ║ Matrices d'os dans constantes c397
           ║ États de rendu
           ▼
╔══════════════════════════════════════════════════════════╗
║  D3D9 Software Vertex Processing (driver, sur CPU)       ║
║  (si m_dwNodeCount > 0)                                  ║
║                                                          ║
║  Pour chaque vertex :                                    ║
║    pos_out = Σ(i=0..3) M[bone_i] × pos_in × weight_i   ║
║    nor_out = Σ(i=0..3) N[bone_i] × nor_in × weight_i   ║
║                                                          ║
╚══════════╦═══════════════════════════════════════════════╝
           ║ Vertices transformés
           ▼
╔══════════════════════════════════════════════════════════╗
║  GPU                                                     ║
╠══════════════════════════════════════════════════════════╣
║                                                          ║
║  VS_WMESH.vsh (si m_bUseSHADER = TRUE)                  ║
║    • Skinning GPU (si software VP désactivé)             ║
║    • Gouraud : dot(N, L) par lumière                     ║
║    • Sortie : position clip, couleur, UV                 ║
║                                                          ║
║  Rasterisation                                           ║
║    • Interpolation couleur, UV                           ║
║    • Z-test / Z-write                                    ║
║                                                          ║
║  PS_SHADER.psh                                           ║
║    • texld diffuse (s0)                                  ║
║    • texld détail (s1)                                   ║
║    • Specular Phong : pow(dot(H, N), exp)               ║
║    • Sortie : RGBA final                                 ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
```

---

## 8. Synthèse

| Opération | Où | Fichier | Fréquence |
|---|---|---|---|
| Interpolation position keyframe | CPU | `TachyonAnimation.cpp:905` | Chaque frame, chaque os |
| Interpolation rotation (SLERP) | CPU | `TachyonAnimation.cpp:934` | Chaque frame, chaque os |
| Interpolation scale keyframe | CPU | `TachyonAnimation.cpp:969` | Chaque frame, chaque os |
| Multiplication M_parent × M_enfant | CPU | `TachyonAnimation.cpp:789` | Chaque frame (avec cache) |
| Blending entre animations | CPU | `TachyonAnimation.cpp:623` | Uniquement en transition |
| Frustum culling | CPU | `TachyonObject.cpp:1951` | Chaque frame |
| Sélection LOD | CPU | `TachyonMesh.cpp:828` | Chaque frame |
| Skinning (vertex blending) | **CPU** (software VP D3D9) | Driver D3D9 | Chaque frame, chaque vertex |
| Vertex shader (Gouraud) | **GPU** | `VS_WMESH.vsh` | Si m_bUseSHADER=TRUE |
| Pixel shader (Phong + textures) | **GPU** | `PS_SHADER.psh` | Si m_bUseSHADER=TRUE |
| Rasterisation | **GPU** | — | Toujours |

### Points clés

- **Le skinning est sur CPU** : `D3DVBF_3WEIGHTS` indexé en D3D9 force `SetSoftwareVertexProcessing(TRUE)`, ce qui fait exécuter la déformation des vertices par le pilote D3D sur le CPU, pas sur le GPU.
- **Le GPU ne voit jamais les os** en mode fixed-function : il reçoit des vertices déjà transformés.
- **Le vertex shader GPU** (`VS_WMESH.vsh`) n'est actif que si `m_bUseSHADER = TRUE` — dans ce cas c'est le GPU qui fait le skinning via les constantes `c397`.
- **Les VBs sont statiques** : aucun lock/unlock par frame. La position bind-pose des vertices ne change jamais dans le buffer.
- **Le cache de matrices** (`bNeedCompute`) est la principale optimisation CPU : si un personnage n'a pas bougé et que son animation n'a pas avancé, `GetFrameMatrix()` est entièrement skippée.
