//*********************************************************
//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
//*********************************************************
#define END_SEARCH -1
#define IGNORE      0
#define ACCEPT      1

#define TOP_LEVEL_INDEX 0
#define BOTTOM_LEVEL_INDEX 1
#define NUM_BVH_LEVELS 2

static
uint2 stacks[NUM_BVH_LEVELS][TRAVERSAL_MAX_STACK_DEPTH];

#if ENABLE_ACCELERATION_STRUCTURE_VISUALIZATION
RWTexture2D<float4> g_screenOutput : register(u0);

void VisualizeAcceleratonStructure(uint depth)
{   
    if (depth >= 22)
    {
        g_screenOutput[DispatchRaysIndex().xy] = float4((depth - 21) / 11.0, 0, 0, 1);
    }
    else if (depth >= 10)
    {
        g_screenOutput[DispatchRaysIndex().xy] = float4(0, (depth - 9) / 12.0, 0, 1);
    }
    else
    {
        g_screenOutput[DispatchRaysIndex().xy] = float4(0, 0, depth / 9.0, 1);
    }
}

static 
uint depthStack[NUM_BVH_LEVELS][TRAVERSAL_MAX_STACK_DEPTH];

static float g_closestBoxT = FLT_MAX;
static int g_hitDepth = 0;
#endif

void RecordClosestBox(uint currentLevel, inout bool leftTest, float leftT, inout bool rightTest, float rightT, inout float closestBoxT)
{
#if ENABLE_ACCELERATION_STRUCTURE_VISUALIZATION
    if (Debug.LevelToVisualize == currentLevel)
    {
        if (rightTest)
        {
            closestBoxT = min(closestBoxT, rightT);
            rightTest = false;
        }

        if (leftTest)
        {
            closestBoxT = min(closestBoxT, leftT);
            leftTest = false;
        }
    }
#endif
}

void StackPush(inout int stackTop, uint level, uint2 nodeInfo, uint depth)
{
    uint stackIndex = stackTop++;

#if ENABLE_ACCELERATION_STRUCTURE_VISUALIZATION
    depthStack[level][stackIndex] = depth;
#endif
    
    stacks[level][stackIndex] = nodeInfo;
}

uint2 StackPop(inout int stackTop, uint level, out uint depth)
{
    uint stackIndex = --stackTop;

#if ENABLE_ACCELERATION_STRUCTURE_VISUALIZATION
    depth = depthStack[level][stackIndex];
#endif

    return stacks[level][stackIndex];
}

int InvokeAnyHit(int stateId)
{
    Fallback_SetAnyHitResult(ACCEPT);
    Fallback_CallIndirect(stateId);
    return Fallback_AnyHitResult();
}

void Fallback_IgnoreHit()
{
    Fallback_SetAnyHitResult(IGNORE);
}

void Fallback_AcceptHitAndEndSearch()
{
    Fallback_SetAnyHitResult(END_SEARCH);
}

bool IsOpaque(bool geomOpaque, uint instanceFlags, uint rayFlags)
{
    bool opaque = geomOpaque;

    if (instanceFlags & INSTANCE_FLAG_FORCE_OPAQUE)
        opaque = true;
    else if (instanceFlags & INSTANCE_FLAG_FORCE_NON_OPAQUE)
        opaque = false;

    if (rayFlags & RAY_FLAG_FORCE_OPAQUE)
        opaque = true;
    else if (rayFlags & RAY_FLAG_FORCE_NON_OPAQUE)
        opaque = false;

    return opaque;
}

int Fallback_ReportHit(float tHit, uint hitKind)
{
    if (tHit < RayTMin() || Fallback_RayTCurrent() <= tHit)
        return 0;

    Fallback_SetPendingRayTCurrent(tHit);
    Fallback_SetPendingHitKind(hitKind);
    int stateId = Fallback_AnyHitStateId();
    int ret = ACCEPT;

    bool geomOpaque = true; // TODO: This should be looked up with the triangle data.
    // TODO: Need to get instance flags
    if (stateId > 0 && !IsOpaque(geomOpaque, 0, RayFlags()))
        ret = InvokeAnyHit(stateId);

    if (ret != IGNORE)
    {
        Fallback_CommitHit();
        if (RayFlags() & RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH)
            ret = END_SEARCH;
    }
    return ret;
}

// Call this only when necessary as saving off 3x4 matrices is costly
void UpdateObjectSpaceProperties(float3 objectRayOrigin, float3 objectRayDirection, float3x4 worldToObject, float3x4 objectToWorld )
{
    Fallback_SetObjectRayOrigin(objectRayOrigin);
    Fallback_SetObjectRayDirection(objectRayDirection);
    Fallback_SetWorldToObject(worldToObject);
    Fallback_SetObjectToWorld(objectToWorld);
}

//
// Ray/AABB intersection, separating axes theorem
//

inline
bool RayBoxTest(
    out float resultT,
    float closestT,
    float3 rayOriginTimesRayInverseDirection,
    float3 rayInverseDirection,
    float3 boxCenter,
    float3 boxHalfDim)
{
    const float3 relativeMiddle = boxCenter * rayInverseDirection - rayOriginTimesRayInverseDirection; // 3
    const float3 maxL = relativeMiddle + boxHalfDim * abs(rayInverseDirection); // 3
    const float3 minL = relativeMiddle - boxHalfDim * abs(rayInverseDirection); // 3

    const float minT = max(max(minL.x, minL.y), minL.z); // 1
    const float maxT = min(min(maxL.x, maxL.y), maxL.z); // 1

    resultT = max(minT, 0);
    return max(minT, 0) < min(maxT, closestT);
}

float3 Swizzle(float3 v, int3 swizzleOrder)
{
    return float3(v[swizzleOrder.x], v[swizzleOrder.y], v[swizzleOrder.z]);
}

bool IsPositive(float f) { return f > 0.0f; }

// Using Woop/Benthin/Wald 2013: "Watertight Ray/Triangle Intersection"
inline
void RayTriangleIntersect(
    inout float hitT,
    in uint instanceFlags,
    out float2 bary,
    float3 rayOrigin,
    float3 rayDirection,
    int3 swizzledIndicies,
    float3 shear,
    float3 v0,
    float3 v1,
    float3 v2)
{
    // Woop Triangle Intersection
    bool useCulling = !(instanceFlags & D3D12_RAYTRACING_INSTANCE_FLAG_TRIANGLE_CULL_DISABLE);
    bool flipFaces = instanceFlags & D3D12_RAYTRACING_INSTANCE_FLAG_TRIANGLE_FRONT_COUNTERCLOCKWISE;
    uint backFaceCullingFlag = flipFaces ? RAY_FLAG_CULL_FRONT_FACING_TRIANGLES : RAY_FLAG_CULL_BACK_FACING_TRIANGLES;
    uint frontFaceCullingFlag = flipFaces ? RAY_FLAG_CULL_BACK_FACING_TRIANGLES : RAY_FLAG_CULL_FRONT_FACING_TRIANGLES;
    bool useBackfaceCulling = useCulling && (RayFlags() & backFaceCullingFlag);
    bool useFrontfaceCulling = useCulling && (RayFlags() & frontFaceCullingFlag);

    float3 A = Swizzle(v0 - rayOrigin, swizzledIndicies);
    float3 B = Swizzle(v1 - rayOrigin, swizzledIndicies);
    float3 C = Swizzle(v2 - rayOrigin, swizzledIndicies);

    A.xy = A.xy - shear.xy * A.z;
    B.xy = B.xy - shear.xy * B.z;
    C.xy = C.xy - shear.xy * C.z;
    precise float U = C.x * B.y - C.y * B.x;
    precise float V = A.x * C.y - A.y * C.x;
    precise float W = B.x * A.y - B.y * A.x;

    float det = U + V + W;
    if (useFrontfaceCulling)
    {
        if (U > 0.0f || V > 0.0f || W > 0.0f) return;
    }
    else if (useBackfaceCulling)
    {
        if (U < 0.0f || V < 0.0f || W < 0.0f) return;
    }
    else
    {
        if ((U < 0.0f || V < 0.0f || W < 0.0f) &&
            (U > 0.0f || V > 0.0f || W > 0.0f)) return;
    }

    if (det == 0.0f) return;
    A.z = shear.z * A.z;
    B.z = shear.z * B.z;
    C.z = shear.z * C.z;
    const float T = U * A.z + V * B.z + W * C.z;

    if (useFrontfaceCulling)
    {
        if (T > 0.0f || T < hitT * det)
            return;
    }
    else if (useBackfaceCulling)
    {
        if (T < 0.0f || T > hitT * det)
            return;
    }
    else
    {
        float signCorrectedT = abs(T);
        if (IsPositive(T) != IsPositive(det))
        {
            signCorrectedT = -signCorrectedT;
        }

        if (signCorrectedT < 0.0f || signCorrectedT > hitT * abs(det))
        {
            return;
        }
    }

    const float rcpDet = rcp(det);
    bary.x = V * rcpDet;
    bary.y = W * rcpDet;
    hitT = T * rcpDet;
}

#define MULTIPLE_LEAVES_PER_NODE 0
static
bool TestLeafNodeIntersections(
    RWByteAddressBufferPointer accelStruct,
    uint2 flags,
    uint instanceFlags,
    float3 rayOrigin,
    float3 rayDirection,
    int3 swizzledIndicies,
    float3 shear,
    inout float2 resultBary,
    inout float resultT,
    inout uint resultTriId)
{
    // Intersect a bunch of triangles
    const uint firstId = GetLeafIndexFromInfo(flags);
    const uint numTris = GetNumPrimitivesFromInfo(flags);

    // Unroll mildly, it'd be awesome if we had some helpers here to intersect.
    uint i = 0;
    bool bIsIntersect = false;
#if MULTIPLE_LEAVES_PER_NODE
    const uint evenTris = numTris & ~1;
    for (i = 0; i < evenTris; i += 2)
    {
        const uint id0 = firstId + i;

        const uint2 triIds = uint2(id0, id0 + 1);

        // Read 3 vertices
        // This is pumping too much via SQC
        float3 v00, v01, v02;
        float3 v10, v11, v12;
        BVHReadTriangle(accelStruct, v00, v01, v02, triIds.x);
        BVHReadTriangle(accelStruct, v10, v11, v12, triIds.y);

        // Intersect
        float2 bary0, bary1;
        float t0 = resultT;
        RayTriangleIntersect(
            t0,
            instanceFlags,
            bary0,
            rayOrigin,
            rayDirection,
            swizzledIndicies,
            shear,
            v00, v01, v02);

        float t1 = resultT;
        RayTriangleIntersect(
            t1,
            instanceFlags,
            bary1,
            rayOrigin,
            rayDirection,
            swizzledIndicies,
            shear,
            v10, v11, v12);

        // Record nearest
        if (t0 < resultT)
        {
            resultBary = bary0.xy;
            resultT = t0;
            resultTriId = triIds.x;
            bIsIntersect = true;
        }

        if (t1 < resultT)
        {
            resultBary = bary1.xy;
            resultT = t1;
            resultTriId = triIds.y;
            bIsIntersect = true;
        }
    }

    if (numTris & 1)
#endif
    {
        const uint triId0 = firstId + i;

        // Read 3 vertices
        float3 v0, v1, v2;
        BVHReadTriangle(accelStruct, v0, v1, v2, triId0);

        // Intersect
        float2  bary0;
        float t0 = resultT;
        RayTriangleIntersect(
            t0,
            instanceFlags,
            bary0,
            rayOrigin,
            rayDirection,
            swizzledIndicies,
            shear,
            v0, v1, v2);

        // Record nearest
        if (t0 < resultT && t0 > RayTMin())
        {
            resultBary = bary0.xy;
            resultT = t0;
            resultTriId = triId0;
            bIsIntersect = true;
        }
    }
    return bIsIntersect;
}

int GetIndexOfBiggestChannel(float3 vec)
{
    if (vec.x > vec.y && vec.x > vec.z)
    {
        return 0;
    }
    else if (vec.y > vec.z)
    {
        return 1;
    }
    else
    {
        return 2;
    }
}

void swap(inout int a, inout int b)
{
    int temp = a;
    a = b;
    b = temp;
}

struct HitData
{
    uint ContributionToHitGroupIndex;
    uint PrimitiveIndex;
};

struct RayData
{
    // Precalculated Stuff for intersection tests
    float3 InverseDirection;
    float3 OriginTimesRayInverseDirection;
    float3 Shear;
    int3   SwizzledIndices;
};

RayData GetRayData(float3 rayOrigin, float3 rayDirection)
{
    RayData data;

    // Precompute stuff
    data.InverseDirection = rcp(rayDirection);
    data.OriginTimesRayInverseDirection = rayOrigin * data.InverseDirection;

    int zIndex = GetIndexOfBiggestChannel(abs(rayDirection));
    data.SwizzledIndices = int3(
        (zIndex + 1) % 3,
        (zIndex + 2) % 3,
        zIndex);

    if (rayDirection[data.SwizzledIndices.z] < 0.0f) swap(data.SwizzledIndices.x, data.SwizzledIndices.y);

    data.Shear = float3(
        rayDirection[data.SwizzledIndices.x] / rayDirection[data.SwizzledIndices.z],
        rayDirection[data.SwizzledIndices.y] / rayDirection[data.SwizzledIndices.z],
        1.0 / rayDirection[data.SwizzledIndices.z]);

    return data;
}

bool Cull(bool opaque, uint rayFlags)
{
    return (opaque && (rayFlags & RAY_FLAG_CULL_OPAQUE)) || (!opaque && (rayFlags & RAY_FLAG_CULL_NON_OPAQUE));
}

float ComputeCullFaceDir(uint instanceFlags, uint rayFlags)
{
    float cullFaceDir = 0;
    if (rayFlags & RAY_FLAG_CULL_FRONT_FACING_TRIANGLES)
        cullFaceDir = 1;
    else if (rayFlags & RAY_FLAG_CULL_BACK_FACING_TRIANGLES)
        cullFaceDir = -1;
    if (instanceFlags & INSTANCE_FLAG_TRIANGLE_CULL_DISABLE)
        cullFaceDir = 0;

    return cullFaceDir;
}

//
// Explicit phases. This reconverges after reaching leaves. It makes for a more level performance.
//

#if 1
#define MARK(x,y) LogInt(x*100+10+y)

void dump(BoundingBox box, uint2 flags)
{
    LogFloat3(box.center);
    LogFloat3(box.halfDim);
    LogInt2(flags);
}
#else
#define MARK(x,y) 
void dump(BoundingBox box, uint2 flags) {}
#endif

Declare_Fallback_SetPendingAttr(BuiltInTriangleIntersectionAttributes);

#define EndSearch 0x1
#define ProcessingBottomLevel 0x2

void SetBoolFlag(inout uint flagContainer, uint flag, bool enable)
{
    if (enable)
    {
        flagContainer |= flag;
    }
    else
    {
        flagContainer &= ~flag;
    }
}

bool GetBoolFlag(uint flagContainer, uint flag)
{
    return flagContainer & flag;
}

struct BLASContext {
    uint instanceIndex;
    uint instanceFlags;
    uint instanceOffset;
    uint instanceId;
    GpuVA instanceGpuVA;
    
    float3x4 worldToObject; 
    float3x4 objectToWorld;
    float3 objectSpaceOrigin;
    float3 objectSpaceDirection;
    RayData rayData;
};

////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////

inline bool GetBLASFromTopLevelLeaf(
    in uint2 leafInfo,
    in RWByteAddressBufferPointer topLevelAccelerationStructure,
    in uint offsetToInstanceDescs,
    in uint InstanceInclusionMask,
    out BLASContext blasContext
)
{
    MARK(6, 0);
    
    uint leafIndex = GetLeafIndexFromInfo(leafInfo);
    
    BVHMetadata metadata = GetBVHMetadataFromLeafIndex(
        topLevelAccelerationStructure,
        offsetToInstanceDescs,
        leafIndex);
    
    RaytracingInstanceDesc instanceDesc = metadata.instanceDesc;
    
    bool isValidInstance = GetInstanceMask(instanceDesc) & InstanceInclusionMask;

    if (isValidInstance)
    {
        MARK(7, 0);

        blasContext.instanceIndex = metadata.InstanceIndex;
        blasContext.instanceOffset = GetInstanceContributionToHitGroupIndex(instanceDesc);
        blasContext.instanceId = GetInstanceID(instanceDesc);

        blasContext.instanceGpuVA = instanceDesc.AccelerationStructure;
        blasContext.instanceFlags = GetInstanceFlags(instanceDesc);

        blasContext.worldToObject = CreateMatrix(instanceDesc.Transform);
        blasContext.objectToWorld = CreateMatrix(metadata.ObjectToWorld);
        blasContext.objectSpaceOrigin = mul(blasContext.worldToObject, float4(WorldRayOrigin(), 1));
        blasContext.objectSpaceDirection = mul(blasContext.worldToObject, float4(WorldRayDirection(), 0));
        blasContext.rayData = GetRayData(blasContext.objectSpaceOrigin, blasContext.objectSpaceDirection);
    }

    return isValidInstance;
}

inline bool CheckHitProcedural(
    in uint hitGroupRecordOffset,
    in uint primitiveIndex,

    in BLASContext blasContext
)
{
    Fallback_SetPendingCustomVals(hitGroupRecordOffset, primitiveIndex, blasContext.instanceIndex, blasContext.instanceId);
    
    uint intersectionStateId, anyHitStateId;
    GetAnyHitAndIntersectionStateId(HitGroupShaderTable, hitGroupRecordOffset, anyHitStateId, intersectionStateId);

    Fallback_SetAnyHitStateId(anyHitStateId);
    Fallback_SetAnyHitResult(ACCEPT);
    Fallback_CallIndirect(intersectionStateId);
    return (Fallback_AnyHitResult() == END_SEARCH);
}

inline bool CheckHitTriangles(
    in uint2 nodeInfo,
    in uint hitGroupRecordOffset,
    in uint primitiveIndex,
    in bool opaque,

    in RWByteAddressBufferPointer bottomLevelAccelerationStructure,
    
    in BLASContext blasContext,

    in uint searchDepth
)
{
    float resultT = Fallback_RayTCurrent();
    float2 resultBary;
    uint resultTriId;

    // TODO: We need to break out this function so we can run anyhit on each triangle
    bool triangleHit = TestLeafNodeIntersections( 
        bottomLevelAccelerationStructure,
        nodeInfo,
        blasContext.instanceFlags,
        ObjectRayOrigin(),
        ObjectRayDirection(),
        blasContext.rayData.SwizzledIndices,
        blasContext.rayData.Shear,
        resultBary,
        resultT,
        resultTriId);
    
    if (!triangleHit)
    {
        return false;
    }

    uint hitKind = HIT_KIND_TRIANGLE_FRONT_FACE;

    BuiltInTriangleIntersectionAttributes attr;
    attr.barycentrics = resultBary;
    Fallback_SetPendingAttr(attr);
#if !ENABLE_ACCELERATION_STRUCTURE_VISUALIZATION
    Fallback_SetPendingTriVals(hitGroupRecordOffset, primitiveIndex, blasContext.instanceIndex, blasContext.instanceId, resultT, hitKind);
#endif

#if ENABLE_ACCELERATION_STRUCTURE_VISUALIZATION
    g_closestBoxT = min(g_closestBoxT, resultT);
    bool isClosestHit = g_closestBoxT == resultT;
    if (isClosestHit)
    {
        g_hitDepth = searchDepth;
    }
#endif

#ifdef DISABLE_ANYHIT 
    bool skipAnyHit = true;
#else
    bool skipAnyHit = opaque;
#endif
    
    bool hitEndsSearch;

    if (skipAnyHit)
    {
        MARK(8, 1);
        Fallback_CommitHit();
        hitEndsSearch = (RayFlags() & RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH);
    }
    else
    {
        MARK(8, 2);
        uint anyhitStateId = GetAnyHitStateId(HitGroupShaderTable, hitGroupRecordOffset);
        int ret = ACCEPT;
        
        if (anyhitStateId)
        {
            ret = InvokeAnyHit(anyhitStateId);
        }
        
        if (ret != IGNORE)
        {
            Fallback_CommitHit();
        }

        hitEndsSearch = (ret == END_SEARCH) || (RayFlags() & RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH);
    }

    return hitEndsSearch;
}

inline bool CheckHitOnBottomLevelLeaf(
    in uint2 leafInfo,

    in RWByteAddressBufferPointer bottomLevelAccelerationStructure,
    in BLASContext blasContext,

    in uint RayContributionToHitGroupIndex,
    in uint MultiplierForGeometryContributionToHitGroupIndex,

    in uint searchDepth
)
{
    MARK(8, 0);
    
    const uint leafIndex = GetLeafIndexFromInfo(leafInfo);
    PrimitiveMetaData primitiveMetadata = BVHReadPrimitiveMetaData(bottomLevelAccelerationStructure, leafIndex);

    bool geomOpaque = primitiveMetadata.GeometryFlags & D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE;
    bool opaque = IsOpaque(geomOpaque, blasContext.instanceFlags, RayFlags());
    bool culled = Cull(opaque, RayFlags());

    bool isProceduralGeometry = IsProceduralGeometry(leafInfo);
#ifdef DISABLE_PROCEDURAL_GEOMETRY
    isProceduralGeometry = false;
#endif

    if (!culled)
    {
        uint hitGroupGeometryContribution = primitiveMetadata.GeometryContributionToHitGroupIndex * MultiplierForGeometryContributionToHitGroupIndex;
        uint hitGroupRecordIndex = RayContributionToHitGroupIndex + hitGroupGeometryContribution + blasContext.instanceOffset;
        uint hitGroupRecordOffset = HitGroupShaderRecordStride * hitGroupRecordIndex;

        uint primitiveIndex = primitiveMetadata.PrimitiveIndex;
        if (isProceduralGeometry)
        {
            return CheckHitProcedural(
                hitGroupRecordOffset,
                primitiveIndex,
                blasContext
            );
        }
        else // Triangle Geometry
        {
            return CheckHitTriangles(
                leafInfo,
                hitGroupRecordOffset,
                primitiveIndex,
                opaque,
                bottomLevelAccelerationStructure,
                blasContext,
                searchDepth
            );
        }
    }

    return false;
}

static
bool Traverse(
    uint InstanceInclusionMask,
    uint RayContributionToHitGroupIndex,
    uint MultiplierForGeometryContributionToHitGroupIndex
)
{
    uint GI = Fallback_GroupIndex();

    RayData currentRayData = GetRayData(WorldRayOrigin(), WorldRayDirection());

    uint nodesToProcess[NUM_BVH_LEVELS];
    nodesToProcess[TOP_LEVEL_INDEX] = 0;
    nodesToProcess[BOTTOM_LEVEL_INDEX] = 0;
    uint currentBVHLevel = TOP_LEVEL_INDEX;

    BLASContext blasContext;

    RWByteAddressBufferPointer topLevelAccelerationStructure = CreateRWByteAddressBufferPointerFromGpuVA(TopLevelAccelerationStructureGpuVA);
    uint offsetToInstanceDescs = GetOffsetToInstanceDesc(topLevelAccelerationStructure);
    RWByteAddressBufferPointer currentBVH = topLevelAccelerationStructure;

    float closestBoxT = FLT_MAX;
    int NO_HIT_SENTINEL = ~0;
    Fallback_SetInstanceIndex(NO_HIT_SENTINEL);

    uint currentDepth = 0;

    uint2 rootInfo = 0;
    StackPush(nodesToProcess[TOP_LEVEL_INDEX], TOP_LEVEL_INDEX, rootInfo, currentDepth);

    uint moo = 0;
    MARK(2, 0);
    do
    {
        MARK(3, 0);
        uint2 parentNodeInfo = StackPop(nodesToProcess[currentBVHLevel], currentBVHLevel, currentDepth);
        bool isLeaf = IsLeaf(parentNodeInfo);
        uint childIndex = GetChildIndexFromInfo(parentNodeInfo);

        if (isLeaf)
        {
            MARK(5, 0);
            if (currentBVHLevel == TOP_LEVEL_INDEX)
            {
                MARK(6, 0);
                if (GetBLASFromTopLevelLeaf(
                    parentNodeInfo,
                    topLevelAccelerationStructure,
                    offsetToInstanceDescs,
                    InstanceInclusionMask,
                    blasContext
                ))
                {
                    MARK(7, 0);
                    
                    currentRayData = blasContext.rayData;
                    currentBVH = CreateRWByteAddressBufferPointerFromGpuVA(blasContext.instanceGpuVA);
                    
                    UpdateObjectSpaceProperties(
                        blasContext.objectSpaceOrigin, 
                        blasContext.objectSpaceDirection, 
                        blasContext.worldToObject, 
                        blasContext.objectToWorld
                    );
                    
                    StackPush(nodesToProcess[BOTTOM_LEVEL_INDEX], BOTTOM_LEVEL_INDEX, rootInfo, currentDepth + 1);
                    currentBVHLevel = BOTTOM_LEVEL_INDEX;
                    // g_hitDepth = moo; 
                }
            }
            else // if it's a bottom level
            {
                if(CheckHitOnBottomLevelLeaf(
                    parentNodeInfo,
                    currentBVH,
                    blasContext,
                    RayContributionToHitGroupIndex,
                    MultiplierForGeometryContributionToHitGroupIndex,
                    currentDepth
                ))
                {
                    break;
                }
                // g_hitDepth = moo == 1 ? 8 : 30;
            }
        }
        else
        {
            moo++;
            MARK(4, 0);
            BoundingBox leftBox, rightBox;
            uint2 leftInfo, rightInfo;
            bool leftHit, rightHit;
            float leftT, rightT;

            leftBox = GetLeftBoxFromBVH(currentBVH, childIndex, leftInfo);
            rightBox = GetRightBoxFromBVH(currentBVH, childIndex, rightInfo);
            
            leftHit = RayBoxTest(
                leftT,
                RayTCurrent(),
                currentRayData.OriginTimesRayInverseDirection,
                currentRayData.InverseDirection,
                leftBox.center,
                leftBox.halfDim);

            rightHit = !IsDummy(rightInfo) && RayBoxTest(
                rightT,
                RayTCurrent(),
                currentRayData.OriginTimesRayInverseDirection,
                currentRayData.InverseDirection,
                rightBox.center,
                rightBox.halfDim);

            bool singleHit, doubleHit;
            
            singleHit = leftHit || rightHit;
            doubleHit = leftHit && rightHit;

            uint2 firstInfo, secondInfo;

            if (doubleHit)
            {
                if (rightT < leftT)
                {
                    firstInfo = rightInfo; secondInfo = leftInfo;
                }
                else // If equal, traverse the left side first since it's encoded to have fewer triangles
                {
                    firstInfo = leftInfo; secondInfo = rightInfo;  
                }
            }
            else if (singleHit)
            {
                firstInfo = leftHit ? leftInfo : rightInfo;
            }

            if (doubleHit)
            {
                StackPush(nodesToProcess[currentBVHLevel], currentBVHLevel, secondInfo, currentDepth + 1);
            }

            if (singleHit)
            {
                StackPush(nodesToProcess[currentBVHLevel], currentBVHLevel, firstInfo, currentDepth + 1);
            }
        }

        if (nodesToProcess[BOTTOM_LEVEL_INDEX] == 0)
        {
            if (currentBVHLevel == BOTTOM_LEVEL_INDEX)
            {
                currentBVHLevel = TOP_LEVEL_INDEX;
                currentRayData = GetRayData(WorldRayOrigin(), WorldRayDirection());
                currentBVH = topLevelAccelerationStructure;
            }
        }
    } while(nodesToProcess[currentBVHLevel] != 0);
    MARK(10,0);

    bool isHit = Fallback_InstanceIndex() != NO_HIT_SENTINEL;
#if ENABLE_ACCELERATION_STRUCTURE_VISUALIZATION
    VisualizeAcceleratonStructure(g_hitDepth);
#endif

    return isHit;
}