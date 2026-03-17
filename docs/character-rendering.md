# Affichage des personnages — Documentation technique

> Basé sur l'analyse du code source `Z:\TClient` (moteur Tachyon Engine, DirectX 9, C++/MFC)

---

## Table des matières

1. [Vue d'ensemble](#1-vue-densemble)
2. [Boucle de rendu principale](#2-boucle-de-rendu-principale)
3. [Structures de données](#3-structures-de-données)
4. [Système d'animation squelettique](#4-système-danimation-squelettique)
5. [Pipeline de rendu du mesh](#5-pipeline-de-rendu-du-mesh)
6. [Application des matrices aux os](#6-application-des-matrices-aux-os)
7. [Frustum culling](#7-frustum-culling)
8. [LOD et optimisations](#8-lod-et-optimisations)
9. [Fichiers clés](#9-fichiers-clés)
10. [Schéma récapitulatif](#10-schéma-récapitulatif)

---

## 1. Vue d'ensemble

Le moteur utilise un pipeline classique DirectX 9 avec animation squelettique par vertex blending indexé. Chaque personnage est représenté par un `CTachyonObject` contenant :

- Une hiérarchie d'os (`m_pBone[]`) calculée chaque frame
- Un ou plusieurs meshes pondérés par os (`WMESHVERTEX`)
- Des objets enfants pour les équipements attachés aux os
- Un cache d'optimisation pour éviter de recalculer les matrices si rien n'a changé

Deux modes de rendu coexistent : **shader** (vertex shader avec constantes) et **fixed-function** (D3DTS_WORLDMATRIX + D3DVBF_3WEIGHTS).

---

## 2. Boucle de rendu principale

**Fichiers :** `TachyonApp.cpp`, `TachyonWnd.cpp`

```
CTachyonApp::Run()
    └─ CTachyonApp::MainProc()          ← appelé chaque frame
           └─ CTachyonWnd::Render()     ← si fenêtre active et pas de cinématique
```

```cpp
// TachyonApp.cpp ~ligne 326
if (!m_pTachyonWnd->m_bOnMovie) {
    if (CWnd::GetForegroundWindow() != m_pTachyonWnd)
        m_dwSLEEP = 10;         // 10ms si fenêtre inactive
    m_pTachyonWnd->Render();
}
```

`CTachyonWnd::Render()` itère sur tous les personnages visibles dans la scène et appelle `CTachyonObject::Render()` pour chacun.

---

## 3. Structures de données

### Instance de personnage : `CTachyonObject`
**Fichier :** `TachyonObject.h`

| Membre | Type | Rôle |
|--------|------|------|
| `m_vPosition` | `D3DXMATRIX` | Matrice de position dans le monde |
| `m_pBone[]` | `LPD3DXMATRIX` | Matrices des os calculées chaque frame |
| `m_pBlend[]` | `LPD3DXMATRIX` | Matrices de la frame précédente (pour le blending) |
| `m_pBlendKEY[]` | `LPD3DXQUATERNION` | Quaternions de blending |
| `m_pPivot` | `LPTPIVOT` | Points de pivot des os |
| `m_fActTime` | `FLOAT` | Temps courant dans l'animation |
| `m_mapEQUIP` | `MAPOBJECT` | Objets enfants (armes, armures) |
| `m_bLOD` | `BYTE` | LOD activé/désactivé |
| `m_bUseSHADER` | `BOOL` | Mode shader ou fixed-function |
| `m_bAlpha` | `BYTE` | Transparence |

### Os et animation : structures clés
**Fichier :** `T3D.h`

```cpp
struct tagBONESANIMATION {
    int   m_nPositionKeyCount;   // Nombre de keyframes de position
    int   m_nRotationKeyCount;   // Nombre de keyframes de rotation
    int   m_nScaleKeyCount;      // Nombre de keyframes de scale
    LPVOID m_pPositionKey;       // Tableau de TPOINTKEY  { DWORD time, D3DXVECTOR3 pos }
    LPVOID m_pRotationKey;       // Tableau de TROTKEY    { DWORD time, D3DXQUATERNION rot }
    LPVOID m_pScaleKey;          // Tableau de TSCALEKEY  { DWORD time, D3DXVECTOR3 scale }
};

struct tagTPIVOT {
    D3DXVECTOR3    m_vScale;     // Scale de l'os
    D3DXQUATERNION m_vRot;       // Rotation de l'os
};
```

---

## 4. Système d'animation squelettique

**Fichiers :** `TachyonAnimation.cpp`, `TachyonObject.cpp`

### Format de fichier

Les animations sont chargées depuis des fichiers **TAF** (Tachyon Animation File, version 1) :

```
[int  version]
[DWORD nodeCount]      ← nombre d'os
[DWORD startTick]
[DWORD endTick]
[D3DXMATRIX × nodeCount]   ← matrices de bind pose inversées
[par os : posKeys + rotKeys + scaleKeys]
```

### Mise à jour par frame

```cpp
// TachyonObject.cpp ~ligne 944
void CTachyonObject::CalcTick(LPDIRECT3DDEVICE9 pDevice, DWORD dwTick) {
    m_fActTime += CTMath::GetTimeValue(dwTick);   // Avance le temps d'anim

    if (m_dwBlendTick < m_dwBlend)
        m_dwBlendTick += dwTick;                  // Avance le blend

    if (m_fActTime >= fTotal) { /* loop / message fin */ }

    CalcFrame(FALSE);  // Recalcule position/rotation
}
```

### Interpolation des keyframes

`CTachyonAnimation::GetFrameMatrix()` (~ligne 702) calcule pour chaque os :

| Composante | Méthode |
|------------|---------|
| Position | Interpolation linéaire entre `TPOINTKEY` |
| Rotation | **SLERP** entre quaternions `TROTKEY` |
| Scale | Interpolation linéaire entre `TSCALEKEY` |

La hiérarchie squelettique est respectée : la matrice de chaque os est combinée avec celle de son parent.

```cpp
// Blending entre deux animations
if (bBlend) {
    vRot = D3DXQuaternionSlerp(&pBlend[...], &vRot, fBlendTime);
}
pResult[i] = LocalTransform * ParentTransform;
```

---

## 5. Pipeline de rendu du mesh

**Fichiers :** `TachyonMesh.cpp`, `TachyonObject.cpp`

### Formats de vertex

| Format | FVF | Utilisé pour |
|--------|-----|-------------|
| `WMESHVERTEX` | `D3DFVF_XYZB4 \| D3DFVF_LASTBETA_UBYTE4 \| D3DFVF_NORMAL \| D3DFVF_TEX1` | Mesh avec os (personnages) |
| `MESHVERTEX` | `D3DFVF_XYZ \| D3DFVF_NORMAL \| D3DFVF_TEX2` | Mesh statique (objets sans animation) |

`WMESHVERTEX` contient 3 poids par vertex (`m_fWeight[3]`) et un index d'os (`m_dwMatIndex`).

### Format de fichier mesh

Les meshes sont chargés depuis des fichiers **TMF** (Tachyon Mesh File, version 300) :

```
[int  version]
[DWORD nodeCount]         ← 0 = pas de bones
[FLOAT radius]            ← rayon de la sphère englobante
[D3DXVECTOR3 center]      ← centre de la sphère
[D3DXMATRIX × nodeCount]  ← matrices de bind pose inversées
[vertex buffer data]
[DWORD meshCount]
[index buffer data]
```

### Appels DirectX par part

```cpp
// TachyonObject.cpp ~ligne 1484
void CTachyonObject::Render(CD3DDevice *pDevice, CD3DCamera *pCamera) {
    // 1. Distance caméra → sélection du niveau LOD
    FLOAT fDIST = D3DXVec3Length(&(pos - camera));

    // 2. Application des matrices d'os au GPU
    ApplyMatrix(pDevice);

    // 3. Pour chaque part (corps, tête, armure…)
    for (auto part : m_OBJ.m_mapDRAW) {
        // Textures
        ApplyTexture(pDevice, pPART->m_pTEX, ...);

        // Blend modes (transparence, effets)
        pDevice->SetRenderState(D3DRS_SRCBLEND,  pTEX->m_dwSRCBlend);
        pDevice->SetRenderState(D3DRS_DESTBLEND, pTEX->m_dwDESTBlend);

        // Shaders ou fixed-function
        if (m_bUseSHADER) {
            pDevice->SetVertexShader(pDevice->m_pVertexShader[m_nVS]);
            pDevice->SetPixelShader(pDevice->m_pPixelShader[nPS]);
        } else {
            pDevice->SetRenderState(D3DRS_VERTEXBLEND,
                nodeCount ? D3DVBF_3WEIGHTS : D3DVBF_DISABLE);
        }

        // Sélection du niveau LOD
        int nLevel = m_bLOD ? pPART->m_pMESH->GetLevel(fDIST) : 0;

        // Draw call
        pPART->m_pMESH->Render(pDevice->m_pDevice, pPART->m_dwIndex, nLevel);
    }

    // 4. Objets enfants (équipements) attachés aux os
    for (auto equip : m_mapEQUIP) {
        equip->m_vPosition *= m_pBone[boneID];
        equip->Render(pDevice, pCamera);
    }
}
```

### Draw call final

```cpp
// TachyonMesh.cpp ~ligne 664
pDevice->SetStreamSource(0, pVB, 0,
    nodeCount ? sizeof(WMESHVERTEX) : sizeof(MESHVERTEX));
pDevice->SetIndices(pIB);
pDevice->SetRenderState(D3DRS_INDEXEDVERTEXBLENDENABLE,
    nodeCount ? TRUE : FALSE);

pDevice->DrawIndexedPrimitive(
    D3DPT_TRIANGLELIST,
    vertexOffset, 0,
    vertexCount,
    indexOffset,
    triangleCount);    // indexCount / 3

pDevice->SetRenderState(D3DRS_INDEXEDVERTEXBLENDENABLE, FALSE);
```

---

## 6. Application des matrices aux os

**Fichier :** `TachyonObject.cpp` ~ligne 1146

```cpp
void CTachyonObject::ApplyMatrix(CD3DDevice *pDevice) {
    // Optimisation : ne recalcule que si quelque chose a changé
    BYTE bNeedCompute =
        (m_fActTime   != m_fActTimeLast)   ||
        (m_dwBlendTick != m_dwBlendTickLast) ||
        (m_vPosition._41 != m_fPosLastX)   ||
        (m_vPosition._42 != m_fPosLastY)   ||
        (m_vPosition._43 != m_fPosLastZ);

    if (bNeedCompute) {
        pDATA->m_pAni->GetFrameMatrix(
            m_pBone, m_pBlend, m_pBlendKEY, m_pPivot,
            m_vPosition, 0,                   // root bone
            pANI->m_pANI->m_fLocalTime,
            fBlendTime);
    }

    if (m_bUseSHADER) {
        // Transpose + passage en constante de vertex shader
        D3DXMatrixTranspose((LPD3DXMATRIX) vWORLD, m_pBone);
        pDevice->m_pDevice->SetVertexShaderConstantF(
            VC_WORLD, vWORLD, 3 * (nodeCount + 1));
    } else {
        // Fixed-function : D3DTS_WORLDMATRIX(0..n)
        pDevice->m_pDevice->SetTransform(D3DTS_WORLDMATRIX(0), &m_pBone[0]);
        for (int i = 0; i < nodeCount; i++)
            pDevice->m_pDevice->SetTransform(D3DTS_WORLDMATRIX(i+1),
                &(pInit[i] * m_pBone[i+1]));
    }
}
```

---

## 7. Frustum culling

**Fichier :** `TachyonObject.cpp` ~ligne 1951

Le culling est basé sur un **frustum à 5 plans** construit à partir d'un rectangle écran :

```
1. Construire 4 rayons depuis la caméra vers les coins du rectangle
2. Créer 4 plans latéraux (caméra + 2 rayons adjacents)
3. Créer 1 plan near (plan near de la caméra)
4. Tester la sphère englobante du personnage contre les 5 plans
   → si rejeté par un plan : objet non affiché
   → si accepté : objet rendu
```

```cpp
D3DXVECTOR3 vDIR[4] = {
    pCamera->GetRayDirection(rect.left,  rect.top),
    pCamera->GetRayDirection(rect.right, rect.top),
    pCamera->GetRayDirection(rect.right, rect.bottom),
    pCamera->GetRayDirection(rect.left,  rect.bottom)
};

for (int i = 0; i < 4; i++)
    D3DXPlaneFromPoints(&vPLANE[i], &camPos,
        &(camPos + vDIR[i]), &(camPos + vDIR[(i+1)%4]));

D3DXPlaneFromPointNormal(&vPLANE[4],
    &pCamera->m_vPosition,
    &(pCamera->m_vPosition - pCamera->m_vTarget));
```

La distance caméra–personnage (calculée en `Render()`) est également utilisée pour décider de sauter le rendu des personnages trop éloignés.

---

## 8. LOD et optimisations

### LOD (Level of Detail)

**Fichier :** `TachyonMesh.cpp` ~ligne 828

Chaque mesh peut avoir plusieurs niveaux de détail avec des seuils de distance :

```cpp
int CTachyonMesh::GetLevel(FLOAT fDist) {
    int nResult = 0;
    for (int i = 0; i < nCount; i++) {
        if (fDist > m_fLevelFactor * m_vDist[i])
            nResult = i + 1;   // Niveau de moins en moins détaillé
    }
    return min(nResult, nCount);
}
```

`m_fLevelFactor` est un multiplicateur global configurable. `m_vDist` contient les seuils de distance pour chaque niveau.

### Résumé des optimisations

| Optimisation | Mécanisme | Fichier |
|---|---|---|
| Cache de matrices | Skip `GetFrameMatrix()` si position/temps inchangés | `TachyonObject.cpp` |
| LOD | Réduction du nombre de triangles selon la distance | `TachyonMesh.cpp` |
| Frustum culling | Rejet par sphère englobante vs 5 plans | `TachyonObject.cpp` |
| Vertex format | `MESHVERTEX` allégé pour les objets sans os | `TachyonObject.cpp` |
| VB partagé | `VBTYPE_GLOBAL` : vertex buffer partagé entre plusieurs meshes | `TachyonMesh.cpp` |

---

## 9. Fichiers clés

| Fichier | Rôle |
|---------|------|
| `TachyonApp.cpp/h` | Boucle principale, timing |
| `TachyonWnd.cpp/h` | Fenêtre de rendu, gestion de la scène |
| `TachyonObject.cpp/h` | Personnage : animation, culling, dispatch du rendu |
| `TachyonMesh.cpp/h` | Mesh : chargement TMF, LOD, draw calls D3D |
| `TachyonAnimation.cpp/h` | Animation : chargement TAF, interpolation, GetFrameMatrix |
| `TachyonRes.cpp/h` | Chargement et cache des ressources (mesh, anim, texture) |
| `T3D.h` | Définitions de types : WMESHVERTEX, BONESANIMATION, TPIVOT, OBJECT… |
| `D3DDevice.cpp/h` | Device DirectX 9, shaders, états de rendu |
| `D3DCamera.cpp/h` | Caméra, frustum, ray casting |
| `TMath.cpp/h` | Mathématiques : matrices, quaternions, conversion de temps |

---

## 10. Schéma récapitulatif

```
CTachyonApp::MainProc()
│
└─ CTachyonWnd::Render()
   │
   └─ Pour chaque personnage :
      │
      ├─ Calcul distance caméra  →  sélection niveau LOD
      │
      ├─ CTachyonObject::CalcTick()
      │     Accumuler m_fActTime
      │     Avancer blend (m_dwBlendTick)
      │     CalcFrame() → met à jour position/rotation
      │
      └─ CTachyonObject::Render()
            │
            ├─ ApplyMatrix()
            │     Si (temps || position || blend) a changé :
            │       GetFrameMatrix() → m_pBone[0..n]
            │     Mode shader  → SetVertexShaderConstantF()
            │     Mode fixed   → SetTransform(D3DTS_WORLDMATRIX)
            │
            ├─ Pour chaque part (corps, tête, armure…) :
            │     SetTexture()
            │     SetRenderState() blend modes
            │     SetVertexShader() / SetPixelShader()
            │     nLevel = GetLevel(fDIST)
            │     CTachyonMesh::Render()
            │       SetStreamSource(VB)
            │       SetIndices(IB)
            │       D3DRS_INDEXEDVERTEXBLENDENABLE = TRUE
            │       DrawIndexedPrimitive(TRIANGLELIST)
            │
            └─ Pour chaque équipement (arme, bouclier…) :
                  m_vPosition *= m_pBone[boneID]   ← attache à l'os
                  CTachyonObject::Render() récursif
```
