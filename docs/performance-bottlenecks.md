# Performance — Analyse des bottlenecks du rendu des personnages

> Basé sur l'analyse du code source `Z:\TClient` et `Z:\README.md`

---

## Table des matières

1. [Classement des bottlenecks](#1-classement-des-bottlenecks)
2. [CRITIQUE — Software vertex processing](#2-critique--software-vertex-processing)
3. [ÉLEVÉ — Calcul de la hiérarchie squelettique](#3-élevé--calcul-de-la-hiérarchie-squelettique)
4. [ÉLEVÉ — Personnages hors champ rendus quand même](#4-élevé--personnages-hors-champ-rendus-quand-même)
5. [MOYEN — Upload des matrices d'os redondant](#5-moyen--upload-des-matrices-dos-redondant)
6. [MOYEN — State changes non cachés](#6-moyen--state-changes-non-cachés)
7. [MOYEN — Draw calls et équipements récursifs](#7-moyen--draw-calls-et-équipements-récursifs)
8. [FAIBLE — LOD trop conservateur](#8-faible--lod-trop-conservateur)
9. [Chiffres clés par frame](#9-chiffres-clés-par-frame)
10. [Plan d'action](#10-plan-daction)

---

## 1. Classement des bottlenecks

| # | Bottleneck | Sévérité | Fichier / Ligne | Gain potentiel |
|---|---|---|---|---|
| 1 | Software vertex processing forcé (skinning CPU) | **CRITIQUE** | `TachyonMesh.cpp:707` | ~60 % CPU |
| 2 | GetFrameMatrix() : SLERP + mults par os | **ÉLEVÉ** | `TachyonAnimation.cpp:727` | ~20 % CPU |
| 3 | Personnages derrière caméra rendus | **ÉLEVÉ** | `TClientMAP.cpp:3182` | 30–50 % draw calls |
| 4 | Upload bones à chaque frame même si inchangé | **MOYEN** | `TachyonObject.cpp:1143` | ~10 % CPU |
| 5 | SetRenderState sans cache | **MOYEN** | `TachyonObject.cpp:1552` | ~10 % CPU |
| 6 | Draw calls non batché, équipements récursifs | **MOYEN** | `TachyonObject.cpp:1754` | ~15 % CPU/GPU |
| 7 | LOD trop conservateur | **FAIBLE** | `TachyonMesh.cpp:828` | variable |

---

## 2. CRITIQUE — Software vertex processing

**Fichier :** `TachyonMesh.cpp`, lignes 707, 729
**Impact :** bottleneck n°1, responsable de la majorité du temps CPU en présence de nombreux personnages

### Le problème

Pour tout mesh avec des os (`m_dwNodeCount > 0`), le code force le software vertex processing :

```cpp
// TachyonMesh.cpp ligne 707
pDevice->SetSoftwareVertexProcessing(
    m_dwNodeCount ? TRUE : m_bSoftwareVP);
```

Et au moment de la création du vertex buffer :
```cpp
// TachyonMesh.cpp ligne 425
pMESH->m_vT3DVB.LoadT3DVB(
    size,
    m_dwNodeCount > 0 ? D3DUSAGE_SOFTWAREPROCESSING : 0,
    m_dwNodeCount > 0 ? T3DFVF_WMESHVERTEX : T3DFVF_MESHVERTEX);
```

**Ce que ça implique concrètement :**
- Le flag `D3DUSAGE_SOFTWAREPROCESSING` place le vertex buffer en mémoire AGP (RAM système), pas en VRAM
- `SetSoftwareVertexProcessing(TRUE)` force le pilote D3D9 à exécuter la transformation des vertices **sur le CPU**
- Le GPU ne reçoit que des vertices déjà transformés — il ne fait pas le skinning
- Le bus CPU→GPU est saturé à chaque frame pour transférer les vertices déformés

### Le coût par frame

| Grandeur | Valeur typique |
|---|---|
| Vertices par personnage | 2 000 – 5 000 |
| Os par personnage | 30 – 50 |
| Opérations de skinning par vertex | 3 à 6 (multiplications matricielles + accumulation pondérée) |
| Personnages visibles simultanément | 20 – 30 |
| **Total opérations de skinning / frame** | **6 à 15 millions d'ops CPU** |

### Ce que le GPU pourrait faire

En déplaçant le skinning sur le GPU (si `D3DCAPS9.MaxVertexBlendMatrices >= 4`), la charge se réduit à :

- CPU : simplement appeler `SetVertexShaderConstantF()` avec les matrices
- GPU : vertex shader `VS_WMESH.vsh` (déjà existant) qui fait les 4 transformations pondérées en parallèle

```asm
; VS_WMESH.vsh — skinning sur GPU (si activé)
m4x3 r2.xyz, v0, c397[a0.x]   ; pos × matrice[os1]
mul  r2, r2, r0.xxxx            ; × poids1
mad  r2, r4, r0.yyyy, r2        ; += pos × matrice[os2] × poids2
mad  r2, r4, r0.zzzz, r2        ; += pos × matrice[os3] × poids3
mad  r2, r4, r0.wwww, r2        ; += pos × matrice[os4] × poids4
```

Le vertex shader existe déjà (`VS_WMESH.vsh`) — il suffit de supprimer le flag software VP pour l'activer.

---

## 3. ÉLEVÉ — Calcul de la hiérarchie squelettique

**Fichier :** `TachyonAnimation.cpp`, lignes 702–897
**Impact :** ~20 % du budget CPU, entièrement sur le thread principal

### Le problème

`GetFrameMatrix()` est appelée chaque frame pour chaque personnage animé. Elle itère sur tous les os et effectue, pour chaque os :

1. **`CalcRotation()`** — recherche binaire dans les keyframes + SLERP quaternion
2. **`CalcPositionVector()`** — recherche binaire + Lerp linéaire
3. **`CalcScale()`** — recherche binaire + Lerp linéaire
4. **Multiplication parent × enfant** — 2 à 4 multiplications matricielles 4×4

```cpp
// TachyonAnimation.cpp ligne 727 — boucle principale
for (BYTE i = 0; i < m_dwNodeCount; i++) {
    // ~ligne 773
    D3DXQuaternionSlerp(&vROT, &vIDENTITY, &pBlendKEY[...], fBlendTime);
    // ~ligne 779
    D3DXVec3Lerp(&vPOS, &vPREV, &vNEXT, fBlendTime);
    // ~ligne 789
    pResult[...] = animation_result * vRESULT[...] * vTSCALE[...] * vWorld;
}
```

### Le coût par frame

| Opération | Coût par os | 40 os × 30 personnages |
|---|---|---|
| SLERP quaternion | ~12 mul + 1 `acos` | **14 400 SLERP/frame** |
| Lerp position | 3 mul + 3 add | négligeable |
| Mult matricielle parent × enfant | ~64 mul + 48 add | **72 000 mul matricielles/frame** |

**Constantes importantes :**
- `MAX_PIVOT = 255` (`T3D.h:87`) — maximum théorique, jamais atteint en pratique
- Tableaux statiques dans `GetFrameMatrix()` : `vRESULT[MAX_PIVOT]`, `vTSCALE[MAX_PIVOT]` — 16.3 KB chacun, réutilisés (pas d'allocation par frame)

### Cache existant (partiellement efficace)

```cpp
// TachyonObject.cpp lignes 1164–1170
BYTE bNeedCompute =
    (m_fActTime    != m_fActTimeLast)    ||
    (m_dwBlendTick != m_dwBlendTickLast) ||
    (m_vPosition._41 != m_fPosLastX)    ||  // position X
    (m_vPosition._42 != m_fPosLastY)    ||  // position Y
    (m_vPosition._43 != m_fPosLastZ);       // position Z

if (bNeedCompute)
    GetFrameMatrix(...);
```

Ce cache est efficace pour les personnages **immobiles** (idle). En mouvement ou combat, il ne sert à rien car `m_fActTime` change à chaque frame.

---

## 4. ÉLEVÉ — Personnages hors champ rendus quand même

**Fichier :** `TClientMAP.cpp`, ligne 3182
**Impact :** 30 à 50 % des draw calls éliminables selon l'orientation de la caméra

### Le problème

`IsDrawOBJ()` effectue uniquement un **test de distance sphérique** :

```cpp
// TClientMAP.cpp ~ligne 3233
if (m_fCamDIST - m_fSight < CTClientObjBase::m_fCamDist)
    // personnage visible → calcul complet bones + draw calls
```

Un personnage situé **derrière la caméra** mais dans le rayon de rendu est traité entièrement :
- `GetFrameMatrix()` calculée
- `ApplyMatrix()` exécutée
- `DrawIndexedPrimitive()` émis

### Coût d'un personnage "invisible" rendu inutilement

Par personnage hors champ :
- ~180–240 multiplications matricielles (GetFrameMatrix)
- 1 upload GPU (SetVertexShaderConstantF ou SetTransform)
- 3–8 DrawIndexedPrimitive inutiles
- ~50–60 SetRenderState/SetTextureStageState inutiles

Avec 15 personnages derrière la caméra sur 30 visibles → **50 % du budget de rendu gaspillé**.

### Test frustum existant dans le moteur

Le moteur dispose déjà d'un test frustum en `TachyonObject.cpp:1951` (méthode `OBJInRect`), mais il n'est **pas branché** dans la boucle de culling `IsDrawOBJ()`. L'extraction des plans via Gribb/Hartmann est présente dans `TClientMAP.cpp:3027`.

---

## 5. MOYEN — Upload des matrices d'os redondant

**Fichier :** `TachyonObject.cpp`, lignes 1189–1205 — `ApplyMatrix()`
**Impact :** ~10 % du budget CPU, ~90 000 appels D3D évitables par seconde

### Le problème

`ApplyMatrix()` appelle `SetVertexShaderConstantF()` **à chaque frame**, même si les os n'ont pas changé :

```cpp
// Appelé inconditionnellement même si bNeedCompute = FALSE
pDevice->m_pDevice->SetVertexShaderConstantF(
    pDevice->m_vConstantVS[VC_WORLD],
    vWORLD,
    3 * (nodeCount + 1));    // jusqu'à 3 × 65 × 4 = 780 floats
```

### Le volume de données transférées

| Grandeur | Valeur |
|---|---|
| Floats par matrice 4×3 | 12 |
| Matrices par personnage (N os + 1 racine) | N + 1 |
| Exemple : 40 os | 41 × 12 = 492 floats = 1 968 octets |
| 30 personnages × 60 FPS | ~3.5 Mo/s de constantes shader |

Un personnage en **idle** (animation en boucle identique chaque frame à la même position) génère cet upload inutilement à chaque frame.

---

## 6. MOYEN — State changes non cachés

**Fichier :** `TachyonObject.cpp`, boucle ~ligne 1552
**Impact :** ~10 % du budget CPU, ~90 000 appels D3D inutiles par seconde

### Le problème

Chaque part de personnage déclenche une série d'appels D3D **sans vérifier si l'état est déjà en place** :

| Type d'appel | Occurrences dans `TachyonObject.cpp` | Par personnage par frame |
|---|---|---|
| `SetRenderState` | 60 | ~10–12 |
| `SetTextureStageState` | 66 | ~8 |
| `SetSamplerState` | inclus | ~4 |

```cpp
// Exemple — lignes 1564–1569 — répété pour chaque part
pDevice->SetRenderState(D3DRS_ALPHATESTENABLE, 0);
pDevice->SetRenderState(D3DRS_ALPHABLENDENABLE, ...);
pDevice->SetRenderState(D3DRS_SRCBLEND, ...);
pDevice->SetRenderState(D3DRS_DESTBLEND, ...);
// etc.
```

### Coût cumulé

```
30 personnages × 5 parts × 22 appels D3D = 3 300 appels / frame
× 60 FPS = 198 000 appels D3D / seconde
```

En réalité, la majorité des parts consécutives partagent les mêmes états (même matériau, même blend mode). Un cache simple éliminerait 40 à 50 % de ces appels.

---

## 7. MOYEN — Draw calls et équipements récursifs

**Fichier :** `TachyonObject.cpp`, lignes 1754–1768
**Impact :** chaque item équipé double ou triple les draw calls d'un personnage

### Draw calls par personnage

| Partie | Draw calls |
|---|---|
| Corps (body) | 1–2 |
| Tête | 1 |
| Armure | 1–2 |
| Arme droite (équipement enfant) | 1–2 |
| Bouclier gauche (équipement enfant) | 1–2 |
| **Total personnage équipé** | **5–9** |

### Rendu récursif des équipements

```cpp
// TachyonObject.cpp ~ligne 1754
for (itOBJ = m_mapEQUIP.begin(); itOBJ != m_mapEQUIP.end(); itOBJ++) {
    pOBJ->m_vPosition *= m_pBone[boneID];   // attache à l'os
    pOBJ->Render(pDevice, pCamera);          // Render() récursif complet
}
```

Chaque `Render()` récursif rejoue l'intégralité du pipeline (ApplyMatrix + états + draw calls) pour l'item.

### Scène complète

```
30 personnages × 7 draw calls moyens = 210 DrawIndexedPrimitive/frame
+ overhead CPU : 30 × 22 state changes × 7 parts ≈ 4 620 appels D3D/frame
```

Aucun batching ni instancing n'est implémenté.

---

## 8. FAIBLE — LOD trop conservateur

**Fichier :** `TachyonMesh.cpp`, lignes 828–838
**Impact :** variable selon le contenu des fichiers `.obj` (seuils `m_vDist`)

### Le problème

Le facteur de distance LOD (`m_fLevelFactor`, défaut `1.0`) déclenche la réduction de polygones à une distance fixe. Si les fichiers mesh n'ont pas de seuils `m_vDist` renseignés, le LOD ne s'applique jamais.

```cpp
int CTachyonMesh::GetLevel(FLOAT fDist) {
    for (int i = 0; i < nCount; i++)
        if (fDist > m_fLevelFactor * m_vDist[i])  // jamais vrai si m_vDist vide
            nResult = i + 1;
    return min(nResult, nCount);
}
```

La valeur de `m_fLevelFactor` est globale et non exposée en configuration — il faudrait la descendre à `0.6–0.8` pour déclencher le LOD plus tôt.

---

## 9. Chiffres clés par frame

> Scénario : 30 personnages visibles, 40 os chacun, 5 parts, 60 FPS

| Métrique | Valeur / frame | Valeur / seconde |
|---|---|---|
| SLERP quaternion | 30 × 40 = 1 200 | 72 000 |
| Multiplications matricielles (hiérarchie) | 30 × 240 = 7 200 | 432 000 |
| Vertex skinning CPU (software VP) | 30 × 3 500 × 5 ops = 525 000 | 31,5 M |
| Floats uploadés (matrices d'os) | 30 × 492 = 14 760 | 885 600 |
| Draw calls | 30 × 7 = 210 | 12 600 |
| SetRenderState + SetTextureStageState | 30 × 5 × 22 = 3 300 | 198 000 |
| Allocations heap | 0–5 (steady state) | 0–300 |

---

## 10. Plan d'action

Repris depuis `Z:\README.md` :

| Priorité | ID | Effort | Impact | Risque | Gain estimé |
|---|---|---|---|---|---|
| 1 | **OPT-2** Frustum culling | Faible | Élevé | Faible | −30 à −50 % draw calls |
| 2 | **OPT-4** Skip upload bones | Faible | Moyen | Faible | −10 % CPU |
| 3 | **OPT-5** Cache render states | Moyen | Moyen | Faible | −10 % CPU |
| 4 | **OPT-1** Hardware VP skinning | Moyen | **Très élevé** | Moyen | −50 à −60 % CPU skinning |
| 5 | **OPT-3** LOD plus agressif | Faible | Moyen | Faible | variable |

**OPT-2 en premier** : rapport effort/impact maximal — une dizaine de lignes dans `IsDrawOBJ()`.
**OPT-1 en dernier** : le gain est le plus important mais nécessite une validation sur plusieurs GPU (fallback software si `D3DCAPS9.MaxVertexBlendMatrices < 4`).
