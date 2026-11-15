# Especificação SDD: Paridade Shapr3D em Modelagem B-Rep, Extrusão, Faces, Quinas (Chanfro/Fillet) e Cura Localizada de Cantos

**Status:** Pronto para Implementação  
**Padrão Metodológico:** Spec-Driven Development (SDD)  
**Alvo:** `openshape3d` (Kernel OCCT C++ Bridge + Kernel Swift + FeatureGraph Paramétrico + Editor 3D)  
**Referências de Código-Fonte Auditadas:**
- `openshape3d/Kernel/OCCT/OCCTBridge.h` & `openshape3d/Kernel/OCCT/OCCTBridge.mm`
- `openshape3d/Kernel/OCCT/OCCTKernel.swift`
- `openshape3d/Kernel/KernelOps.swift`
- `openshape3d/Kernel/FaceTopology.swift` & `openshape3d/Kernel/EdgeTopology.swift`
- `openshape3d/Kernel/DeleteFaceKit.swift`
- `openshape3d/Model/ElementNaming.swift` & `openshape3d/Model/FeatureGraph.swift`
- `openshape3d/Editor/EditorViewModel.swift`

---

## 1. Contexto e Objetivo Arquitetural

No **Shapr3D** (baseado em Parasolid + motor híbrido de Modelagem Direta e Histórico Paramétrico), toda operação sobre sólidos opera estritamente sobre a representação de fronteira (**B-Rep**: `Solid` $\rightarrow$ `Shell` $\rightarrow$ `Face` $\rightarrow$ `Loop/Wire` $\rightarrow$ `Coedge/Half-Edge` $\rightarrow$ `Edge` $\rightarrow$ `Vertex`), mantendo a malha de triângulos (`MeshData`) exclusivamente como cache visual e de *hit-testing* mapeado 1:1 para os identificadores topológicos (`faceIndex` 1-based do kernel e `ElementName` persistente).

Esta especificação **SDD (Spec-Driven Development)** consolida:
1. O diagnóstico exato de todas as lacunas e bugs atuais do `openshape3d` em relação ao Shapr3D.
2. Os contratos formais de dados, assinaturas de métodos C++/Objective-C++ (`OCCTBridge`) e Swift (`OCCTKernel`, `FaceTopology`, `DeleteFaceKit`, `FeatureGraph`, `EditorViewModel`).
3. O comportamento matemático e topológico determinístico para **Extrusão**, **Offset Face**, **Chanfro (Chamfer)**, **Arredondamento (Fillet)** e **Remoção/Conversão Localizada de Cantos Arredondados (`Delete Face` / `Defeaturing`)**, garantindo que **desfazer ou remover um único canto arredondado ou chanfrado restaure exclusivamente aquela quina aguda (`Edge` + `Vertices`) sem unificar nem fundir faces/elementos adjacentes**.
4. O roteiro sequencial passo a passo de implementação e a matriz de testes verificáveis (BDD / XCTest).

---

## 2. Diagnóstico Técnico das Lacunas Atuais no `openshape3d`

A auditoria do código-fonte identificou **7 gargalos estruturais** que impedem a paridade total com o Shapr3D hoje:

| ID | Componente / Arquivo | Diagnóstico Técnico Exato | Impacto no Usuário |
| :--- | :--- | :--- | :--- |
| **GAP-01** | `DeleteFaceKit.swift:58-75`<br>`FeatureGraph.swift:2005-2015` | **Bug do Quarto de Cilindro (`samplePoint` em Fillet de 90°):** `DeleteFaceKit.target(cylindrical:)` e `FeatureGraph.samplePoint(on:)` calculam `samplePoint` somando um vetor radial arbitrário (`cross(axis, (1,0,0))` ou `(0,1,0)`) ao ponto no eixo (`onAxis`). Em um furo de 360° isso cai sobre a superfície, mas em um **fillet de quina (arco de 90°)**, em 3 das 4 quinas de um bloco o ponto cai no vazio fora da face B-Rep recortada (a $\approx 1{,}414 \cdot R$ da face real). O `OS3DNearestFaces` (`OCCTBridge.mm:2216`) falha com `noTargetMatched` ou remove a parede plana vizinha por engano. | Tentar deletar/desfazer um canto arredondado específico falha em 75% das orientações de quina ou remove a face errada. |
| **GAP-02** | `DeleteFaceKit.swift:80-89`<br>`FaceTopology.swift:374-418` | **Rejeição de Faces de Fillet Toroidais, Esféricas e Cônicas:** `DeleteFaceKit.target(in:seedTriangle:)` só aceita `FaceTopology.cylindricalFace` ou `FaceTopology.planarFace`. Fillets em bordas de cilindros geram faces **Toroidais (`GeomAbs_Torus`)**; encontros de 3 arestas arredondadas geram **Patches Esféricos (`GeomAbs_Sphere` / `BSpline`)**; chanfros em cilindros geram **Cones (`GeomAbs_Cone`)**. Todos retornam `nil` ("That surface isn't a face this tool can remove"). | Impossível remover/curar quinas arredondadas de 3 arestas (vértices de bola) ou fillets em peças cilíndricas. |
| **GAP-03** | `OCCTBridge.h:358`<br>`OCCTBridge.mm:2201-2237`<br>`OCCTKernel.swift:679` | **Acoplamento Frágil por Ponto 3D em vez de Índice Topológico B-Rep (`faceIndex`):** `defeaturedShape` resolve a face B-Rep apenas por proximidade espacial de `samplePoint` (`BRepExtrema_DistShapeShape`), ignorando o canal `faceRegions` (`OCCTKernel.renderMeshFaceChannel(from: brep)`) que já mapeia cada triângulo renderizado exatamente para o índice 1-based do `TopExp::MapShapes(shape, TopAbs_FACE)`! | Em fillets de raio muito pequeno ($R < 0{,}5\text{ mm}$), a busca por ponto pode colidir com a parede lateral adjacente. |
| **GAP-04** | `EditorViewModel.swift:4158-4204`<br>`EditorViewModel.swift:5069` | **Fluxo Incompleto ao Deletar/Converter um Único Canto Arredondado:**<br>1. No modo padrão do viewport 3D, selecionar uma face de fillet/chanfro e acionar `Delete` não dispara a cura localizada (`Delete Face` / `BRepAlgoAPI_Defeaturing`) diretamente sobre a face selecionada.<br>2. Em `beginBlendEdit` (`EditorViewModel.swift:4187`), ao reeditar as arestas de um fillet no histórico para desmarcar um único canto, o código usa apenas `EdgeTopology.resolve($0.signature, in: preBody.mesh)` e **ignora `EdgeRef.faceNames`**, podendo perder a correspondência quando a geometria a montante mudou. | O usuário não consegue clicar em um único canto arredondado e apertar `Delete` para voltar à quina viva localmente, nem editar com precisão 100% determinística a lista de arestas por `faceNames`. |
| **GAP-05** | `OCCTBridge.h:407`<br>`OCCTBridge.mm:2678-2682`<br>`FeatureGraph.swift:585` | **Chanfro Assimétrico (2 Distâncias / Distância + Ângulo) Não Conectado ao OCCT:** `EditorViewModel` possui `blendValue2: Double?` e `KernelOps.blendEdges` aceita `amountB`, mas `OCCTBridge.chamferedShape` chama apenas `mk.Add(amount, edge)` (simétrico) e `FeatureKind.chamfer` persiste apenas `distance: Expr`. | Chanfros no caminho B-Rep real (`Body.brep`) são sempre simétricos de $45^\circ$, ignorando `blendValue2`. |
| **GAP-06** | `OCCTKernel.swift:958-1035`<br>`FeatureGraph.swift:1416-1486` | **`Push/Pull` (`Offset Face`) em Parede Inclinada e Cilindro Analítico:**<br>1. `pushPullResult` constrói um prisma ortogonal (`pushPullToolForShape`) e faz booleana. Em um bloco com paredes inclinadas (*draft*), puxar a face superior cria um degrau reto em vez de estender as paredes inclinadas.<br>2. O offset radial de furos/pinos cilíndricos em `FeatureGraph.evalPushPull` (`linha 1463`) cai para malha (`KernelOps.offsetCylinderRadius`) e **descarta o `Body.brep` (`brep: nil`)**, quebrando operações B-Rep subsequentes. | Puxar faces adjacentes a chanfros/drafts cria degraus indesejados; alterar o diâmetro de um furo destrói o B-Rep do corpo. |
| **GAP-07** | `FeatureGraph.swift:537-575`<br>`OCCTKernel.swift` | **Variantes de Alcance (`Extent`) e Início (`Start`) na Extrusão:** `FeatureKind.extrude` suporta apenas `depth: Expr` e `symmetric: Bool`, faltando `Extent = .toObject(targetFace/Body, offset)` e `.throughAll`, além de `startOffset: Expr?` e seleção explícita de `targetBodies` no booleano. | Extrusões precisam de cálculo manual de distância quando deveriam terminar exatamente em outra face/corpo (`To Object`) ou atravessar tudo (`Through All`). |

---

## 3. Especificações Funcionais e Algorítmicas (Contratos SDD)

### SPEC-01: Mapeamento Determinístico Triângulo $\leftrightarrow$ `TopoDS_Face` e Seleção de Faces no Viewport 3D

#### 1.1 Regra de Invariância Topológica
Todo `Body` com `brep != nil` DEVE manter em `MeshData.faceRegions` (`[Int]`, mesmo comprimento de `triangles`) o índice 1-based exato da `TopoDS_Face` gerado por `OCCTKernel.renderMeshFaceChannel(from: brep)` (que reflete a ordem de `TopExp::MapShapes(shape, TopAbs_FACE)`).

#### 1.2 Resolução Híbrida de Face (`FaceTargetResolution`)
Qualquer ferramenta que opere sobre uma face clicada no viewport (`Delete Face`, `Offset Face / Push-Pull`, `Draft`, `Shell`, seleção direta de face de Fillet/Chanfro) DEVE identificar a face B-Rep usando a seguinte ordem de precedência:
1. **Prioridade 1 — `ElementName` Persistente (`ElementNaming.FaceName`):** Quando a operação vem da reavaliação do `FeatureGraph`, resolve via `Body.faceNames` $\rightarrow$ índice 1-based da `TopoDS_Face`.
2. **Prioridade 2 — Índice Direto de `faceRegions` (`occtFaceIndex`):** Quando o usuário clica no triângulo `seedTriangle` e `mesh.faceRegions.indices.contains(seedTriangle)` com `mesh.faceRegions[seedTriangle] > 0`, todos os triângulos com o mesmo `faceRegions[i]` formam exatamente a `TopoDS_Face` (seja ela plana, cilíndrica de 90°, toroidal, esférica ou BSpline).
3. **Prioridade 3 — Ponto Interior Real de Triângulo (`interiorSamplePoint`):** Para compatibilidade com `OS3DNearestFaces` quando não há índice direto, o `samplePoint` NUNCA deve ser projetado em uma direção radial arbitrária (`(1,0,0)`). Ele DEVE ser calculado a partir do baricentro do **maior triângulo pertencente àquela face** (`bestTriangleCentroid`), projetado ortogonalmente sobre a superfície analítica (ou mantido no baricentro do triângulo, que por definição da triangulação `BRepMesh_IncrementalMesh` jaz exatamente sobre a `TopoDS_Face` recortada!).

```swift
// Contrato em DeleteFaceKit.swift e FeatureGraph.swift
public struct FaceRemovalTarget: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case holeOrFilletCylinder = "Cylindrical Face"
        case planarFace = "Planar Face"
        case blendOrCurvedFace = "Curved / Blend Face" // Torus, Sphere, Cone, BSpline
    }

    public let kind: Kind
    public let triangles: Set<Int>
    public let occtFaceIndex: Int?       // 1-based index em TopExp::MapShapes(TopAbs_FACE)
    public let samplePoint: SIMD3<Float> // Baricentro projetado a partir de um triângulo REAL da face
    public let sampleNormal: SIMD3<Float>
    public let summary: String
}
```

#### 1.3 Correção Matemática do `samplePoint` em Cilindros Parciais (Fillets de 90°)
Em `DeleteFaceKit.target(cylindrical:)` e `FeatureGraph.samplePoint(on:)`:
```swift
// CORRETO: Usa o baricentro de um triângulo real da face cilíndrica (ex.: maior área)
// para determinar a direção radial exata dentro do arco recortado (90°, 180° ou 360°).
let refCentroid = bestTriangleCentroid(in: cyl.triangles, mesh: mesh)
let along = simd_dot(refCentroid - cyl.origin, cyl.axis)
let onAxis = cyl.origin + cyl.axis * along
let radialVec = refCentroid - onAxis
let radialLen = simd_length(radialVec)
let radialDir = radialLen > 1e-6 ? (radialVec / radialLen) : perpendicularUnit(to: cyl.axis)
let samplePoint = onAxis + radialDir * cyl.radius
let sampleNormal = cyl.isHole ? -radialDir : radialDir
```
*Por que funciona sempre:* `refCentroid` é o centro de um triângulo da própria malha daquela face de fillet. Portanto, `radialDir` aponta exatamente para o meio angular do arco de 90° (a $45^\circ$ da quina), garantindo distância $0{,}0\text{ mm}$ até a `TopoDS_Face` no OCCT.

---

### SPEC-02: Extrusão Completa (`Extrude` & `DraftExtrude`)

#### 2.1 Modelo de Dados Paramétrico (`FeatureKind.extrude`)
O nó de extrusão em `FeatureGraph.swift` deve suportar os modos de início (`ExtrudeStart`) e alcance (`ExtrudeExtent`) do Shapr3D:

```swift
public enum ExtrudeStart: Codable, Equatable, Sendable {
    case profilePlane
    case offset(Expr) // Desloca o perfil ao longo da normal antes de iniciar a extrusão
}

public enum ExtrudeExtent: Codable, Equatable, Sendable {
    case distance(Expr)
    case symmetric(Expr)
    case throughAll
    case toFace(bodyID: UUID, faceName: ElementName?, fallbackPoint: SIMD3<Float>, fallbackNormal: SIMD3<Float>, offset: Expr?)
}
```
*(Mantendo retrocompatibilidade de serialização `Codable` com os campos legados `depth: Expr` e `symmetric: Bool`).*

#### 2.2 Regras de Execução Geométrica
1. **`ExtrudeStart.offset(d)`:** Translada o `TopoDS_Face` do perfil por $\vec{n} \cdot d$ antes de invocar `BRepPrimAPI_MakePrism` ou `BRepOffsetAPI_DraftAngle`.
2. **`ExtrudeExtent.throughAll`:** Calcula a *bounding box* global de todos os corpos visíveis (ou `targetBodies`) projetada no eixo de extrusão $\vec{n}$ e define a distância como $\max(\text{proj}) - \text{origem}_{\text{proj}} + 1{,}0\text{ mm}$ de folga para garantir corte/interseção completa.
3. **`ExtrudeExtent.toFace`:** Resolve a `TopoDS_Face` alvo via `faceName` (ou `fallbackPoint`), calcula a interseção do raio $(\text{centroide}_{\text{perfil}}, \vec{n})$ com a superfície portadora da face alvo (ou usa `BRepFeat_MakePrism` / plano delimitador em `BRepAlgoAPI_Common`/`Cut`), e soma `offset` se fornecido.
4. **Inferência Automática de Booleana (Padrão Shapr3D):**
   - Arraste no sentido que penetra um corpo existente ($\text{volume}(\text{prisma} \cap \text{corpo}) > 10^{-4}$) $\rightarrow$ `.subtract` (*Cut*).
   - Arraste para fora a partir de uma face de corpo existente $\rightarrow$ `.union` (*Union / New Body* alternável no badge flutuante).
   - Perfil isolado sem interseção $\rightarrow$ cria novo `Body`.
5. **Preservação de Paredes Individualizadas (Sem Fusão Global Agressiva):**
   - Na extrusão com booleana (`booleanShape`), `ShapeUpgrade_UnifySameDomain` só deve unificar faces que compartilham o mesmo domínio criadas pela costura booleana se o usuário não tiver divisões intencionais de esboço (*split faces*), preservando `OS3DFillBooleanHistory` para rastrear `modified` e `generated`.

---

### SPEC-03: `Offset Face` Real em B-Rep (Faces Inclinadas e Cilindros Analíticos)

#### 3.1 Offset de Faces Planas com Paredes Adjacentes Inclinadas
No Shapr3D, empurrar/puxar uma face move a superfície portadora ao longo de sua normal e **estende ou apara as superfícies das faces vizinhas** (mantendo os ângulos de inclinação/*draft* das paredes laterais), em vez de criar um degrau vertical.

**Algoritmo em `OCCTBridge.mm` (`offsetSingleFaceOnShape`):**
1. Localizar a `TopoDS_Face` alvo $F_{\text{target}}$ (por `faceIndex` 1-based ou `samplePoint`/`sampleNormal`).
2. Verificar os ângulos diedros entre $F_{\text{target}}$ e todas as suas faces adjacentes $\{F_{\text{adj}}\}$ através das arestas compartilhadas:
   - **Caso A (Todas as faces adjacentes são ortogonais a $F_{\text{target}}$, $\theta = 90^\circ \pm 10^{-3}$):** O caminho rápido atual via prisma booleano (`pushPullToolForShape`) é geometricamente idêntico e pode ser usado como otimização.
   - **Caso B (Existe ao menos uma face adjacente não-ortogonal / inclinada ou cônica):**
     1. Construir o deslocamento local da superfície via `BRepOffset_MakeOffset` (ou construir um sólido estendido projetando os contornos ao longo das direções das paredes adjacentes / substituir a superfície de $F_{\text{target}}$ por um plano deslocado de $d$ e re-interseccionar com os meios-espaços das faces adjacentes via `BRepAlgoAPI_Cut` / `BRepBuilderAPI_MakeSolid` com extensão das superfícies vizinhas).
     2. Registrar `OS3DFillModifierHistory` para manter os `ElementName`s de $F_{\text{target}}$ e das paredes adjacentes inalterados.

#### 3.2 Offset Radial Analítico de Faces Cilíndricas (Furos e Pinos) no B-Rep
Atualmente, `FeatureGraph.evalPushPull` (`FeatureGraph.swift:1463`) aplica `KernelOps.offsetCylinderRadius` apenas na malha e zera `brep: nil`.
**Novo Contrato B-Rep (`OCCTBridge.offsetCylindricalFaceRadius`):**
1. Identificar a `TopoDS_Face` cilíndrica $F_{\text{cyl}}$ no `OCCTShapeRef` (de raio $R_0$, eixo $\vec{A}$, origem $O$, `isHole` detectado pela orientação `TopAbs_REVERSED` vs `TopAbs_FORWARD` da normal da face em relação ao vetor radial).
2. Calcular o novo raio $R_1 = \max(0{,}05, R_0 + \Delta R)$.
3. Construir o cilindro de diferença coaxial entre $R_0$ e $R_1$ limitado exatamente pela extensão axial $[t_{\min}, t_{\max}]$ da face cilíndrica (com extensão para encontrar faces de topo/fundo inclinadas ou planas) e aplicar:
   - Se o furo aumenta ($\Delta R > 0$ em furo) ou pino diminui ($\Delta R < 0$ em pino): `BRepAlgoAPI_Cut` no `OCCTShapeRef`.
   - Se o furo diminui ($\Delta R < 0$ em furo) ou pino aumenta ($\Delta R > 0$ em pino): `BRepAlgoAPI_Fuse` seguido de unificação apenas da parede cilíndrica coaxial (`ShapeUpgrade_UnifySameDomain` restrito ao cilindro), preservando `Body.brep` 100% válido e analítico!

---

### SPEC-04: Chanfro (`Chamfer`) e Arredondamento (`Fillet`) em Quinas e Cantos

#### 4.1 Seleção de Arestas e Propagação de Cadeia Tangente ($G^1$)
1. Uma aresta B-Rep $E$ é identificada univocamente pelo par não-ordenado das suas duas faces adjacentes `{faceNameA, faceNameB}` (`ElementNaming.EdgeName`) + assinatura geométrica de fallback (`EdgeSignature`).
2. Quando `blendChainTangent == true` (padrão no Shapr3D), selecionar uma aresta $E_0$ propaga automaticamente para todas as arestas conectadas nos vértices cujo cosseno entre vetores tangentes nos pontos extremos satisfaça $|\hat{t}_1 \cdot \hat{t}_2| \ge \cos(5^\circ) \approx 0{,}9962$ (`EdgeTopology.tangentChain`).

#### 4.2 Transição Contínua Dinâmica Fillet $\leftrightarrow$ Chamfer pelo Zero
Durante o arraste do manipulador 3D (`EditorViewModel.updateBlendDrag`, linha 4442):
- **Arraste Positivo ($\text{raw} > 0{,}1\text{ mm}$):** Aplica o modo primário (`Fillet` de raio $R = \text{raw}$, ou `Chamfer` de distância $D = \text{raw}$).
- **Zona Morta ($|\text{raw}| \le 0{,}1\text{ mm}$):** Exibe o sólido original com as quinas vivas sem modificador ativo.
- **Arraste Negativo ($\text{raw} < -0{,}2\text{ mm}$):** Quando a operação foi iniciada pelo gesto unificado de aresta (`blendGestureAllowsKindFlip == true`), inverte automaticamente `blendMode` em tempo real:
  - Se iniciou como `.fillet`, converte para `.chamfer` com distância $|\text{raw}|$.
  - Se iniciou como `.chamfer`, converte para `.fillet` com raio $|\text{raw}|$.

#### 4.3 Chanfro Assimétrico no OCCT (`1-Distance` vs `2-Distances` / `Distance + Angle`)
Estender `OCCTBridge.h` / `OCCTBridge.mm` e `FeatureKind.chamfer`:
```objc
// OCCTBridge.h
+ (nullable OCCTShapeRef *)chamferedShape:(OCCTShapeRef *)shape
                                 segments:(const OS3DBlendSegment *)segments
                             segmentCount:(NSUInteger)segmentCount
                                 distance:(double)distance
                                distance2:(double)distance2
                                  history:(OCCTHistory * _Nullable * _Nullable)outHistory
                                    error:(NSError * _Nullable * _Nullable)error;
```
Em `OCCTBridge.mm`:
- Para cada aresta $E$ encontrada em `matchedEdges`, identificar as duas faces incidentes $(F_1, F_2)$ via `TopExp::MapShapesAndAncestors(shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces)`.
- Determinar deterministicamente `faceA` (a face cuja normal média tem maior alinhamento com a orientação canônica do segmento `s.start -> s.end` ou menor `faceIndex`).
- Se `distance2 > 0 && std::abs(distance2 - distance) > 1e-6`:
  chamar `mk.Add(distance, distance2, edge, TopoDS::Face(faceA))`.
- Caso contrário:
  chamar `mk.Add(distance, edge)`.

No `FeatureGraph.swift`:
```swift
case chamfer(id: UUID, name: String, bodyID: UUID, edges: [EdgeRef], distance: Expr, distance2: Expr?)
```

#### 4.4 Resolução de Vértices de 3+ Arestas (*Corner Blend / Setback*)
Quando 3 ou mais arestas que convergem em um mesmo vértice $V$ recebem `Fillet`:
- O `BRepFilletAPI_MakeFillet` do OpenCascade gera automaticamente a **superfície esférica de canto (*rolling-ball corner patch*)** que costura suavemente os 3 tubos de fillet com continuidade $G^1$ nas curvas de recorte (*trim curves*).
- As paredes originais são aparadas nos novos vértices de recuo (*setback vertices* $V_1, V_2, V_3$), e o histórico `OS3DFillModifierHistory` registra tanto as 3 faces tubulares (geradas a partir das arestas $E_1, E_2, E_3$) quanto a face esférica do vértice (gerada a partir do vértice $V$).

---

### SPEC-05: Remoção e Conversão Localizada de Cantos Arredondados (`Delete Face` / `BRepAlgoAPI_Defeaturing`)

> **Requisito Crítico de Paridade Shapr3D:**
> Quando o usuário possui um corpo com múltiplas quinas arredondadas (ou um canto de 3 arestas) e decide **desfazer/remover o arredondamento de apenas UMA quina específica**, a alteração DEVE permanecer **estritamente restrita àquela quina**, reconstruindo apenas a aresta viva ($E_{AB}$) e seus vértices locais pela extensão das duas paredes adjacentes ($F_A$ e $F_B$), **sem alterar as demais quinas arredondadas e sem unificar/fundir elementos adjacentes (faces ou arestas vizinhas)**.

#### 5.1 Fluxos de Interação Suportados para Desfazer Um Canto Arredondado
O `openshape3d` deve suportar **3 formas complementares** (idênticas ao Shapr3D) para desfazer ou converter um canto arredondado específico:

1. **Fluxo A — Seleção Direta da Face do Canto + Tecla/Botão `Delete` (Modelagem Direta):**
   - No modo padrão de seleção do viewport 3D (sem precisar abrir o menu da ferramenta `Delete Face` manualmente), ao tocar na face de um fillet (quarto de cilindro, toro ou patch esférico de canto) ou chanfro, a face individual fica destacada (`selectedFaceRegion` / `selectedDeleteFaceTarget`).
   - Acionar **Delete / Backspace** (ou o botão **Delete Face** no painel de contexto da face selecionada) invoca `commitDeleteSelectedFace()`, que cria/aplica a operação `Delete Face` (`BRepAlgoAPI_Defeaturing`) exclusivamente sobre aquela `TopoDS_Face`.
2. **Fluxo B — Ferramenta Dedicada `Delete Face`:**
   - Com a ferramenta `Delete Face` ativa, clicar em qualquer face de fillet (90° cilíndrica, toroidal, esférica de 3 arestas) ou chanfro a seleciona usando `DeleteFaceKit.target(in: mesh, seedTriangle: hit.triangleIndex)` e executa a cura localizada ao confirmar.
3. **Fluxo C — Edição Seletiva de Arestas no Histórico (`Edit Edges` em `FeatureKind.fillet` / `.chamfer`):**
   - Ao selecionar um nó `.fillet` ou `.chamfer` na árvore de histórico e clicar em **Edit Edges** (`beginBlendEdit`), o usuário pode tocar em **uma única aresta** já incluída no fillet para **desmarcá-la** do conjunto `selectedBlendEdges` e confirmar (`commitBlend()`).
   - O `FeatureGraph` reavalia o nó `.fillet` apenas com as arestas restantes, fazendo com que a quina desmarcada volte a ser viva enquanto as outras permanecem arredondadas.

#### 5.2 Algoritmo de Cura Localizada e Isolamento Estrito (`OCCTBridge.defeaturedShape`)
Em `OCCTBridge.mm`, a remoção de face(s) deve operar com precisão cirúrgica:

```objc
// Nova sobrecarga em OCCTBridge.h que aceita faceIndices 1-based opcionais além de samplePoints:
+ (nullable OCCTShapeRef *)defeaturedShape:(OCCTShapeRef *)shape
                               faceIndices:(nullable NSArray<NSNumber *> *)faceIndices
                              samplePoints:(const simd_float3 *)samplePoints
                             sampleNormals:(const simd_float3 *)sampleNormals
                               sampleCount:(NSUInteger)sampleCount
                                   history:(OCCTHistory * _Nullable * _Nullable)outHistory
                                     error:(NSError * _Nullable * _Nullable)error;
```

**Passo a Passo Interno em `OCCTBridge.mm`:**
1. **Resolução Exata da `TopoDS_Face` Alvo:**
   - Mapear todas as faces do sólido com `TopTools_IndexedMapOfShape faceMap; TopExp::MapShapes(shape->shape, TopAbs_FACE, faceMap);`.
   - Se `faceIndices` for fornecido e válido ($1 \le \text{idx} \le \text{faceMap.Extent()}$), selecionar diretamente `TopoDS::Face(faceMap.FindKey(idx))`.
   - Caso contrário (ou durante reavaliação paramétrica onde os índices mudaram, mas `faceNames` não bateu), usar `OS3DNearestFaces` com o `samplePoint` corrigido (baricentro real do triângulo da face, conforme **SPEC-01**).
2. **Execução do `BRepAlgoAPI_Defeaturing`:**
   ```cpp
   BRepAlgoAPI_Defeaturing defeaturing;
   defeaturing.SetShape(shape->shape);
   for (const TopoDS_Shape &face : targetFaces) {
       defeaturing.AddFaceToRemove(face);
   }
   defeaturing.SetRunParallel(false);
   defeaturing.SetToFillHistory(true);
   defeaturing.Build();
   ```
3. **Garantia de Não-Unificação de Elementos Adjacentes (Isolamento Topológico):**
   - `BRepAlgoAPI_Defeaturing` estende apenas as superfícies portadoras das faces imediatamente adjacentes à face removida ($F_A$ e $F_B$) até que elas se interceptem na nova aresta viva $E_{AB}$ e apara os laços (*wires*) locais.
   - **PROIBIÇÃO EXPLÍCITA:** `defeaturedShape` **NÃO DEVE** invocar `ShapeUpgrade_UnifySameDomain` no sólido resultante!
   - **Por quê:** Evitar `ShapeUpgrade_UnifySameDomain` garante que:
     1. As faces adjacentes $F_A$ e $F_B$ são apenas estendidas até a quina restaurada $E_{AB}$, mantendo seus próprios `ElementName`s (`modified: F_A -> F_A'`, `F_B -> F_B'`).
     2. Se $F_A$ ou $F_B$ possuírem faces coplanares vizinhas (divisões de esboço, outras features, degraus ou impressões), elas **não serão fundidas/unificadas**.
     3. Outros fillets/chanfros vizinhos na mesma peça (ou mesmo outras arestas do mesmo vértice que não foram removidas) permanecem **100% intactos**, sendo apenas estendidos até tocar a nova quina viva $E_{AB}$.

---

### SPEC-06: Persistência de `ElementName` e Edição Determinística no Histórico

#### 6.1 Resolução `faceNames`-First em `EditorViewModel.beginBlendEdit`
Em `EditorViewModel.swift` (linhas 4185–4193), ao abrir um `.fillet` ou `.chamfer` existente para edição:
- Atualmente o código faz apenas:
  `let resolved = Set(edges.compactMap { EdgeTopology.resolve($0.signature, in: preBody.mesh) })`
- **Contrato Corrigido:** Deve usar `FeatureGraph.resolveEdgeRefs(edges, on: preBody)` (ou resolver primeiramente por `EdgeRef.faceNames` cruzando com `preBody.faceNames` + `preBody.mesh.faceRegions`, caindo para `EdgeTopology.resolve($0.signature, ...)` apenas quando `faceNames` não encontrar correspondência). Isso garante que mesmo após alterar dimensões do bloco pai, clicar em **Edit Edges** destaque exatamente as quinas corretas.

#### 6.2 Conversão de Tipo de Feature no Histórico (`Fillet` $\leftrightarrow$ `Chamfer`)
Ao editar uma feature `.fillet` existente no histórico (`editingBlendFeatureID != nil`):
- Permitir alternar o seletor `Fillet | Chamfer` na barra de contexto (ou arrastar através de zero quando autorizado), convertendo o nó existente em `FeatureGraph.features[idx]` de `.fillet` para `.chamfer` (ou vice-versa) mantendo o mesmo `id: UUID` e a mesma lista `edges: [EdgeRef]`, sem perder referências de features dependentes a jusante.

---

## 4. Plano de Implementação Passo a Passo (Ordem de Execução)

A implementação deve seguir estritamente estas **5 fases sequenciais**, compilando e passando os testes ao final de cada fase.

---

### Fase 1: Camada C++ / Objective-C++ (`OCCTBridge.h` & `OCCTBridge.mm`)

1. **Suporte a `faceIndices` Diretos e Isolamento em `defeaturedShape` (`OCCTBridge.h:358`, `OCCTBridge.mm:2201`):**
   - Adicionar o método `+defeaturedShape:faceIndices:samplePoints:sampleNormals:sampleCount:history:error:` em `OCCTBridge`.
   - Quando `faceIndices` contiver índices 1-based válidos, buscar as `TopoDS_Face` diretamente em `TopExp::MapShapes(shape->shape, TopAbs_FACE, faceMap)`.
   - Manter `OS3DNearestFaces` como fallback para amostras sem índice direto, aumentando a tolerância de correspondência normal/superfície para faces curvas pequenas (fillets de raio $\ge 0{,}1\text{ mm}$).
   - Garantir que `ShapeUpgrade_UnifySameDomain` **nunca** seja chamado dentro de `defeaturedShape`, preservando o isolamento estrito da quina restaurada.
2. **Chanfro Assimétrico de 2 Distâncias (`OCCTBridge.h:407`, `OCCTBridge.mm:2631`):**
   - Adicionar o parâmetro `distance2:(double)distance2` em `chamferedShape`.
   - Mapear `TopExp::MapShapesAndAncestors(shape->shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces)` e usar `mk.Add(distance, distance2, edge, TopoDS::Face(faceA))` quando `distance2 > 0 && std::abs(distance2 - distance) > 1e-6`.
3. **Offset Real de Faces B-Rep (`OCCTBridge.h`, `OCCTBridge.mm`):**
   - Implementar `+offsetFaceOnShape:faceIndex:samplePoint:sampleNormal:distance:history:error:` que:
     - Se a `TopoDS_Face` for um cilindro (`GeomAbs_Cylinder`), executa o offset radial analítico no B-Rep preservando `OCCTShapeRef`.
     - Se a `TopoDS_Face` for plana com paredes adjacentes inclinadas ($\theta \neq 90^\circ$), estende as superfícies adjacentes (`BRepOffset_MakeOffset` / reconstrução local de meio-espaço) para não criar degrau vertical.

---

### Fase 2: Camada de Topologia e Kernel Swift (`FaceTopology.swift`, `DeleteFaceKit.swift`, `OCCTKernel.swift`)

1. **Correção do `samplePoint` em Cilindros Parciais (`DeleteFaceKit.swift:58-75`):**
   - Em `DeleteFaceKit.target(cylindrical:)` (e helper compartilhado para `MeshData`), substituir o cálculo de `radial = simd_cross(cyl.axis, seed)` pelo vetor radial extraído do baricentro do maior triângulo de `cyl.triangles` projetado perpendicularmente a `cyl.axis`.
2. **Suporte Universal a Faces B-Rep Curvas em `DeleteFaceKit.target(in:seedTriangle:)` (`DeleteFaceKit.swift:80-89`):**
   - Se `mesh.faceRegions.indices.contains(seedTriangle)` e `let faceIdx = mesh.faceRegions[seedTriangle], faceIdx > 0`:
     - Agrupar todos os triângulos `t` onde `mesh.faceRegions[t] == faceIdx`.
     - Mesmo que `FaceTopology.cylindricalFace` e `FaceTopology.planarFace` retornem `nil` (ex.: face toroidal de fillet em cilindro, patch esférico de canto de 3 arestas, cone ou BSpline), retornar um `FaceRemovalTarget` com `kind: .blendOrCurvedFace`, `occtFaceIndex: faceIdx`, `triangles: regionTriangles`, e `samplePoint` / `sampleNormal` calculados no baricentro do triângulo `seedTriangle` (ou maior triângulo da região).
3. **Exposição no `OCCTKernel.swift` (`OCCTKernel.swift:679`, `OCCTKernel.swift:865`):**
   - Atualizar `OCCTKernel.deleteFaces` para aceitar `faceIndices: [Int] = []` além de `samples` e repassar para `OCCTBridge.defeaturedShape`.
   - Atualizar `OCCTKernel.chamferEdges` para aceitar `distance2: Float? = nil` e repassar `Double(distance2 ?? distance)` para `OCCTBridge.chamferedShape`.
   - Atualizar `OCCTKernel.pushPullResult` para delegar cilindros e faces com vizinhos inclinados ao novo método B-Rep do `OCCTBridge`.

---

### Fase 3: Grafo Paramétrico e Nomeação Topológica (`FeatureGraph.swift`, `ElementNaming.swift`)

1. **Correção de `FeatureGraph.samplePoint(on:)` (`FeatureGraph.swift:2005-2015`):**
   - Atualizar `samplePoint(on: CylindricalFace, in: MeshData)` para usar o baricentro do maior triângulo de `cyl.triangles`, eliminando o bug de 90° também durante o replay de histórico de `FeatureKind.deleteFace`.
2. **Resolução de `DeleteFaceRef` no `FeatureGraph.evalDeleteFace` (`FeatureGraph.swift:1932-2003`):**
   - Quando `DeleteFaceRef.faceName` resolver para o índice 1-based `faceIdx` em `target.faceNames`, passar `faceIndices: [faceIdx]` diretamente para `OCCTKernel.deleteFaces`, garantindo precisão exata em qualquer tipo de face (cilíndrica, toroidal, esférica, plana).
3. **Suporte a `distance2: Expr?` em `FeatureKind.chamfer` (`FeatureGraph.swift:585`):**
   - Adicionar `distance2: Expr? = nil` ao case `.chamfer` (com decodificação retrocompatível via `decodeIfPresent`), avaliando e repassando para `OCCTKernel.chamferEdges` e `KernelOps.blendEdges(..., amountB:)`.
4. **Preservação do `Body.brep` em `evalPushPull` Radial (`FeatureGraph.swift:1463-1474`):**
   - No ramo `.radial(let cyl)` de `evalPushPull`, chamar o caminho B-Rep (`OCCTKernel.offsetCylindricalFace`) quando `target.brep != nil` antes de cair para o fallback de malha, preservando `Body.brep` e atualizando `faceNames` via histórico OCCT.

---

### Fase 4: Viewport 3D e Interação Direta (`EditorViewModel.swift`)

1. **Seleção e Deleção Direta de Canto Arredondado / Face no Viewport (`EditorViewModel.swift`):**
   - Permitir que, ao selecionar uma face de um corpo (especialmente uma face de fillet ou chanfro) e acionar `deleteSelected()` / atalho `Delete` (`Backspace`), se houver uma face sub-selecionada (ou se a ferramenta `Delete Face` estiver ativa), o editor execute `Delete Face` (`BRepAlgoAPI_Defeaturing`) naquela face individual em vez de apagar o corpo inteiro.
2. **Resolução `faceNames`-First em `beginBlendEdit` (`EditorViewModel.swift:4185-4193`):**
   - Substituir a resolução exclusiva por `EdgeSignature` em `beginBlendEdit` por uma resolução híbrida que consulta primeiro `EdgeRef.faceNames` em `preBody` (via `FeatureGraph.resolveEdgeRefs`), garantindo que todas as arestas do fillet sejam recuperadas fielmente para adição/remoção individual de quinas.
3. **Conversão `Fillet` $\leftrightarrow$ `Chamfer` Durante Edição (`EditorViewModel.swift:4480-4525`):**
   - Em `commitBlend()`, se `editingBlendFeatureID` referenciar um `.fillet` mas o usuário tiver trocado `blendMode` para `.chamfer` (por gesto reverso ou toggle na UI), atualizar o nó no `FeatureGraph` para `.chamfer` (e vice-versa) preservando o `id` da feature.
   - Persistir `blendValue2` em `FeatureKind.chamfer(..., distance2:)` quando o modo de chanfro assimétrico estiver ativo.

---

### Fase 5: Suíte de Testes Automatizados (`openshape3dTests`)

Criar o arquivo de testes `openshape3dTests/CornerBlendAndDefeatureParityTests.swift` cobrindo todos os cenários SDD abaixo.

---

## 5. Matriz de Verificação e Critérios de Aceite (BDD / XCTest)

| ID do Teste | Cenário (Given / When / Then) | Invariante Verificado |
| :--- | :--- | :--- |
| **TEST-SDD-01** | **Given** um bloco $20 \times 20 \times 10\text{ mm}$ com as 4 arestas verticais arredondadas por `Fillet` ($R = 3\text{ mm}$) nas 4 orientações de quadrante ($++, -+, --, +-$)<br>**When** `DeleteFaceKit.target` e `OCCTKernel.deleteFaces` são executados em **apenas 1** das 4 faces de fillet (para cada um dos 4 quadrantes)<br>**Then** a operação sucede nos 4 quadrantes, o canto removido volta a ter quina viva de $90^\circ$, e os outros 3 cantos permanecem arredondados com $R = 3\text{ mm}$. | Corrige **GAP-01** e **GAP-03** (bug do quarto de cilindro em 3 dos 4 quadrantes). |
| **TEST-SDD-02** | **Given** um bloco com um canto de 3 arestas convergentes arredondadas (`Fillet` $R = 2\text{ mm}$, gerando 3 fillets cilíndricos + 1 patch esférico de vértice)<br>**When** o usuário remove uma das faces do canto via `DeleteFaceKit` / `deleteFaces`<br>**Then** `DeleteFaceKit.target` reconhece a superfície (incluindo o patch esférico/toroidal) e o `defeaturedShape` cura localmente a topologia sem corromper o sólido (`BRepCheck_Analyzer` válido). | Corrige **GAP-02** (suporte a faces esféricas/toroidais de canto). |
| **TEST-SDD-03** | **Given** um sólido com faces adjacentes divididas (ou múltiplas features vizinhas) e uma quina arredondada entre $F_A$ e $F_B$<br>**When** o arredondamento daquela quina é desfeito via `Delete Face`<br>**Then** $F_A$ e $F_B$ se reconectam na aresta viva $E_{AB}$, o número de faces reduz exatamente em $1$ (apenas a face do fillet sai), e **nenhuma** face adjacente coplanar ou vizinha é unificada/fundida indevidamente. | Garante o **Isolamento Estrito de Quina** (ausência de `UnifySameDomain` global no defeaturing). |
| **TEST-SDD-04** | **Given** um bloco com `Chamfer` assimétrico ($d_1 = 2\text{ mm}, d_2 = 5\text{ mm}$) aplicado em uma aresta via B-Rep<br>**When** o `FeatureGraph` avalia `.chamfer(..., distance: 2, distance2: 5)`<br>**Then** `Body.brep` é preservado, a face de chanfro possui largura $\sqrt{2^2 + 5^2} = \sqrt{29}\text{ mm}$, e as faces adjacentes são recuadas em $2\text{ mm}$ e $5\text{ mm}$ respectivamente. | Corrige **GAP-05** (chanfro assimétrico real no OCCT). |
| **TEST-SDD-05** | **Given** um corpo com um furo cilíndrico de raio $R = 3\text{ mm}$ e `Body.brep != nil`<br>**When** `FeatureKind.pushPull` aplica um offset radial $\Delta R = +1\text{ mm}$ na parede do furo<br>**Then** o furo passa a ter $R = 4\text{ mm}$ e `Body.brep` continua **não-nulo** e válido para receber um `Fillet` subsequente na borda do furo. | Corrige **GAP-06** (preservação do B-Rep em offset radial de cilindro). |
| **TEST-SDD-06** | **Given** um nó `.fillet` aplicado a 4 arestas no `FeatureGraph`, seguido de uma alteração dimensional no esboço base<br>**When** `beginBlendEdit` é chamado e o usuário remove 1 aresta da seleção<br>**Then** as 3 arestas restantes são resolvidas via `EdgeRef.faceNames` e permanecem arredondadas, enquanto a 4ª aresta volta a ser viva. | Corrige **GAP-04** (edição determinística de arestas de blend no histórico). |

---

## 6. Checklist de Definição de Pronto (Definition of Done — DoD)

- [ ] **DoD-1:** `DeleteFaceKit.target` calcula `samplePoint` sempre sobre um triângulo real da face e suporta faces planas, cilíndricas parciais (90°), toroidais, cônicas e patches esféricos (`occtFaceIndex` via `mesh.faceRegions`).
- [ ] **DoD-2:** `OCCTBridge.defeaturedShape` aceita `faceIndices` 1-based, cura quinas arredondadas individualmente via `BRepAlgoAPI_Defeaturing` e **não** unifica elementos adjacentes (`UnifySameDomain` desabilitado no defeaturing).
- [ ] **DoD-3:** `OCCTBridge.chamferedShape` e `FeatureKind.chamfer` suportam chanfro simétrico ($d$) e assimétrico ($d_1, d_2$).
- [ ] **DoD-4:** `EditorViewModel` permite deletar diretamente uma face de fillet/chanfro selecionada para restaurar a quina viva local, converter `Fillet` $\leftrightarrow$ `Chamfer` cruzando o zero, e editar arestas de um blend existente usando resolução `faceNames`-first.
- [ ] **DoD-5:** `OCCTKernel.pushPullResult` e `FeatureGraph.evalPushPull` preservam `Body.brep` em offsets radiais de cilindros e estendem paredes inclinadas em `Offset Face`.
- [ ] **DoD-6:** Todos os testes da suíte `CornerBlendAndDefeatureParityTests` passam sem regressões na suíte principal `xcodebuild test`.
