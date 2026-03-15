# 4Story 3.5 — Plan d'optimisation du rendu des personnages

## Contexte

Le rendu des personnages repose sur un pipeline Direct3D 9 classique.
L'analyse du code source a identifié plusieurs bottlenecks majeurs.
Ce document liste les optimisations planifiées, par ordre d'impact décroissant.

---

## Architecture actuelle

```
ResetVisibleOBJ()          TClientMAP.cpp:3025    culling pre-frame
  IsDrawOBJ()              TClientMAP.cpp:3182    distance cull par objet
RenderTOBJ()               TClientGame.cpp:2120   boucle de rendu (3 passes)
  CTachyonObject::Render() TachyonObject.cpp:1464 rendu 3D d'un personnage
    ApplyMatrix()          TachyonObject.cpp:1143 upload bones -> GPU
    per-mesh-part loop                            SetRenderState + DrawIndexedPrimitive
    equipements recursifs                         Render() sur chaque item equipe
```

### Systemes deja en place

| Systeme             | Fichier                     | Notes                                      |
|---------------------|-----------------------------|--------------------------------------------|
| Distance culling    | TClientMAP.cpp:3182         | `m_fCamDIST - m_fSight < m_fCamDist`      |
| LOD                 | TachyonMesh.cpp:828         | Index buffers reduits selon `fDist`        |
| Grille spatiale 3x3 | TClientMAP.cpp:3041         | Cellules autour de la camera               |
| Alpha fade          | TClientObjBase.cpp:2893     | Fondu avant disparition                    |
| Detail level filter | TClientMAP.cpp:3110         | `m_bDETAILLevel > GetMapDETAILOption()`   |

---

## Optimisations planifiees

### OPT-1 — Hardware Vertex Processing pour le skinning
**Impact : tres eleve**
**Fichier : `TEngine/Engine Lib/TachyonMesh.cpp` ligne ~707**

**Probleme :**
`SetSoftwareVertexProcessing(TRUE)` est force pour tout mesh avec bones.
Le skinning (calcul des positions de vertex a partir des matrices de bones)
se fait sur le CPU. Avec beaucoup de personnages a l'ecran, c'est le
bottleneck principal.

**Solution :**
Detecter au moment de la creation du device si le GPU supporte le
hardware vertex blending (`D3DCAPS9.MaxVertexBlendMatrices >= 4`).
Si oui, desactiver `SetSoftwareVertexProcessing` pour les meshes skinnes.

**Risque :** Certains tres vieux GPUs ne supportent pas 4 matrices de blend.
Prevoir un fallback sur software si la capacite est insuffisante.

---

### OPT-2 — Frustum culling
**Impact : eleve**
**Fichier : `TClient/TClientMAP.cpp` fonction `IsDrawOBJ()` ligne ~3182**

**Probleme :**
Seul un test de distance spherique est effectue. Un personnage situe
derriere la camera mais dans le rayon de rendu est quand meme rendu
entierement (bones calcules, draw calls emis).

**Solution :**
Ajouter un test frustum plan-sphere dans `IsDrawOBJ()` apres le test
de distance. Extraire les 6 plans du frustum depuis la matrice
view*projection (`D3DXMatrixMultiply` + extraction des plans).
Tester la sphere englobante du personnage (`m_fRange` comme rayon)
contre chacun des 6 plans.

**Gain attendu :** Elimine typiquement 30-50% des draw calls selon
l'orientation de la camera.

---

### OPT-3 — LOD plus agressif / ajustement de m_fLevelFactor
**Impact : moyen**
**Fichier : `TEngine/Engine Lib/TachyonMesh.cpp` ligne ~828**

**Probleme :**
Le facteur de distance LOD (`m_fLevelFactor`, defaut 1.0) peut etre
trop conservateur : les personnages proches restent en LOD haute
resolution meme quand ils sont partiellement hors ecran ou peu visibles.

**Solution :**
- Exposer `m_fLevelFactor` comme parametre configurable (registry ou ini).
- Tester des valeurs entre 0.6 et 0.8 pour declencher le LOD plus tot.
- Verifier que les LOD des fichiers .obj sont bien renseignes (`m_vDist`
  non vide) pour les personnages joueurs et monstres principaux.

---

### OPT-4 — Skip upload des bones si animation inchangee
**Impact : moyen**
**Fichier : `TEngine/Engine Lib/TachyonObject.cpp` `ApplyMatrix()` ligne ~1143**

**Probleme :**
`ApplyMatrix()` appelle `SetVertexShaderConstantF()` ou `SetTransform()`
a chaque frame pour chaque personnage, meme s'il est immobile et que
ses bones n'ont pas change depuis la frame precedente.

**Solution :**
Ajouter un flag `m_bBonesUpdated` (BYTE) dans `CTachyonObject`.
Le setter dans `CalcFrame()` met le flag a TRUE.
`ApplyMatrix()` skip l'upload si le flag est FALSE.
Remettre le flag a FALSE apres l'upload.

---

### OPT-5 — Reduction des render state changes
**Impact : moyen**
**Fichier : `TEngine/Engine Lib/TachyonObject.cpp` boucle ligne ~1552**

**Probleme :**
Chaque mesh-part (materiau) d'un personnage appelle plusieurs
`SetRenderState`, `SetTexture`, `SetSamplerState` independamment,
sans verifier si l'etat precedent est deja le bon.

**Solution :**
Introduire un cache d'etat D3D dans `CD3DDevice` (wrapper autour
de `m_pDevice`). Avant chaque `SetRenderState(state, value)`, verifier
si la valeur est deja active. Si oui, skipper l'appel D3D.
Pattern classique : `if(m_dwRSCache[state] != value) { SetRS...; m_dwRSCache[state] = value; }`

---

## Ordre d'implementation recommande

| Priorite | ID     | Effort | Impact | Risque  |
|----------|--------|--------|--------|---------|
| 1        | OPT-2  | Faible | Eleve  | Faible  |
| 2        | OPT-4  | Faible | Moyen  | Faible  |
| 3        | OPT-5  | Moyen  | Moyen  | Faible  |
| 4        | OPT-1  | Moyen  | Tres eleve | Moyen |
| 5        | OPT-3  | Faible | Moyen  | Faible  |

OPT-2 en premier car rapport effort/impact maximal et risque nul.
OPT-1 en dernier car necessite validation sur plusieurs GPU.

---

## Fichiers cles

| Fichier                                        | Role                          |
|------------------------------------------------|-------------------------------|
| `TClient/TClientGame.cpp`                      | Boucle de rendu principale    |
| `TClient/TClientMAP.cpp`                       | Culling et grille spatiale    |
| `TClient/TClientObjBase.cpp`                   | Distance cull par objet       |
| `TEngine/Engine Lib/TachyonObject.cpp`         | Rendu 3D, bones, animation    |
| `TEngine/Engine Lib/TachyonMesh.cpp`           | Draw calls, LOD, VB/IB        |
| `TEngine/Engine Lib/D3DDevice.h`               | Device D3D, shaders           |
| `TEngine/Engine Lib/T3D.h`                     | Formats de vertex             |
