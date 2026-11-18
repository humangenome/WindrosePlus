#define NOMINMAX
// v17.1 — Variable heightfield resolution: 256x256, 160x160, etc.
// v17.1 — An export with no height data (the lobby map, nobody online) no longer replaces terrain_v17.json
//         (terrain_commit.hpp).

#include <Mod/CppUserModBase.hpp>
#include <DynamicOutput/DynamicOutput.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UClass.hpp>
#include <Unreal/AActor.hpp>
#include <Unreal/FProperty.hpp>
#include <windows.h>
#include <fstream>
#include <vector>
#include <cstdint>
#include <filesystem>
#include <map>
#include <set>
#include <cmath>
#include <sstream>
#include "terrain_commit.hpp"

using namespace RC;
using namespace RC::Unreal;

static bool isR(const void*a,size_t l){MEMORY_BASIC_INFORMATION m;if(!VirtualQuery(a,&m,sizeof(m)))return false;if(m.State!=MEM_COMMIT)return false;if(m.Protect&(PAGE_NOACCESS|PAGE_GUARD))return false;return(uintptr_t)a+l<=(uintptr_t)m.BaseAddress+m.RegionSize;}
static bool vp(uint64_t v){return v>0x10000ULL&&v<0x7FFFFFFFFFFFULL;}

class HeightmapExporter : public CppUserModBase {
public:
    HeightmapExporter():CppUserModBase(){ModName=STR("HeightmapExporter");ModVersion=STR("17.1.0");}
    ~HeightmapExporter() override{}
    auto on_unreal_init()->void override{Output::send<LogLevel::Verbose>(STR("[HME] v17.1 variable resolution\n"));}
    auto on_update()->void override{
        m_frameCount++;if(m_frameCount%300!=0)return;
        std::filesystem::path tr[]={"../../../windrose_plus_data/export_heightmap_trigger","windrose_plus_data/export_heightmap_trigger"};
        for(auto&p:tr){try{if(std::filesystem::exists(p)){std::filesystem::remove(p);run();return;}}catch(...){}}
    }
private:
    int m_frameCount=0;
    struct FVec{double X,Y,Z;};

    void run(){
        Output::send<LogLevel::Verbose>(STR("[HME] v17 full export...\n"));
        UClass*hc=nullptr,*lc=nullptr;
        UObjectGlobals::ForEachUObject([&](UObject*o,int32,int32)->RC::LoopAction{
            auto*c=o->GetClassPrivate();if(!c)return RC::LoopAction::Continue;auto n=c->GetName();
            if(!hc&&n==STR("LandscapeHeightfieldCollisionComponent"))hc=c;
            if(!lc&&n==STR("Landscape"))lc=c;
            return RC::LoopAction::Continue;});
        if(!hc||!lc)return;

        struct LI{UObject*o;double x,y,sx;};
        std::vector<LI>lands;std::map<UObject*,int>landMap;
        UObjectGlobals::ForEachUObject([&](UObject*o,int32,int32)->RC::LoopAction{
            if(!o->IsA(lc))return RC::LoopAction::Continue;LI li{};li.o=o;
            FProperty*rp=o->GetPropertyByNameInChain(STR("RootComponent"));
            if(rp){UObject*rc=*static_cast<UObject**>(rp->ContainerPtrToValuePtr<void>(o));
                if(rc){FProperty*lp=rc->GetPropertyByNameInChain(STR("RelativeLocation"));
                    FProperty*sp=rc->GetPropertyByNameInChain(STR("RelativeScale3D"));
                    if(lp){FVec*l=lp->ContainerPtrToValuePtr<FVec>(rc);if(l){li.x=l->X;li.y=l->Y;}}
                    if(sp){FVec*s=sp->ContainerPtrToValuePtr<FVec>(rc);if(s)li.sx=s->X;}}}
            landMap[o]=(int)lands.size();lands.push_back(li);
            return RC::LoopAction::Continue;});

        std::filesystem::path outDir="../../../windrose_plus_data";
        if(!std::filesystem::exists(outDir))outDir="windrose_plus_data";
        auto hdir=outDir/"heightmaps";
        std::filesystem::create_directories(hdir);

        int total=0,withH=0;
        std::ostringstream json;  // written to disk only if it has heights (hme::commitTerrain)
        json<<"{\"version\":17,\"landscapes\":[\n";
        for(size_t i=0;i<lands.size();i++){
            json<<"{\"x\":"<<(int64_t)lands[i].x<<",\"y\":"<<(int64_t)lands[i].y<<",\"sx\":"<<lands[i].sx<<"}";
            if(i<lands.size()-1)json<<",";}
        json<<"],\"components\":[\n";
        bool first=true;

        UObjectGlobals::ForEachUObject([&](UObject*o,int32,int32)->RC::LoopAction{
            if(!o->IsA(hc))return RC::LoopAction::Continue;
            int sx=0,sy=0,li=-1;
            FProperty*sbx=o->GetPropertyByNameInChain(STR("SectionBaseX"));
            FProperty*sby=o->GetPropertyByNameInChain(STR("SectionBaseY"));
            if(sbx){int32_t*v=sbx->ContainerPtrToValuePtr<int32_t>(o);if(v)sx=*v;}
            if(sby){int32_t*v=sby->ContainerPtrToValuePtr<int32_t>(o);if(v)sy=*v;}
            UObject*outer=o->GetOuterPrivate();
            while(outer){auto it=landMap.find(outer);if(it!=landMap.end()){li=it->second;break;}outer=outer->GetOuterPrivate();}
            if(li<0||lands[li].sx==128)return RC::LoopAction::Continue;
            double scale=lands[li].sx>0?lands[li].sx:100.0;
            double wx=lands[li].x+sx*scale,wy=lands[li].y+sy*scale;

            uint8_t*base=reinterpret_cast<uint8_t*>(o);
            bool hasH=false;
            double minZ=0,maxZ=0;
            int32_t hRes=0;

            if(isR(base+1448,8)){
                uint64_t p1=*reinterpret_cast<uint64_t*>(base+1448);
                if(vp(p1)){uint8_t*l1=reinterpret_cast<uint8_t*>(p1);
                    if(isR(l1+48,8)){uint64_t p2=*reinterpret_cast<uint64_t*>(l1+48);
                        if(vp(p2)){uint8_t*fhf=reinterpret_cast<uint8_t*>(p2);
                            if(isR(fhf+0x20,16)){
                                uint64_t hPtr=*reinterpret_cast<uint64_t*>(fhf+0x20);
                                int32_t hNum=*reinterpret_cast<int32_t*>(fhf+0x28);
                                // Accept any reasonable size: must be a perfect square > 1000
                                int32_t side=(int32_t)std::sqrt((double)hNum);
                                if(vp(hPtr)&&hNum>=1000&&hNum<=100000&&side*side==hNum
                                   &&isR(reinterpret_cast<void*>(hPtr),hNum*2)){
                                    uint16_t*h=reinterpret_cast<uint16_t*>(hPtr);
                                    bool var=false;for(int i=1;i<20;i++)if(h[i]!=h[0]){var=true;break;}
                                    if(var){
                                        std::string fn="hf_l"+std::to_string(li)+"_s"+std::to_string(sx)+"_"+std::to_string(sy)+".bin";
                                        std::ofstream bin(hdir/fn,std::ios::binary);
                                        // Write header: resolution (4 bytes) then data
                                        bin.write(reinterpret_cast<char*>(&side),4);
                                        bin.write(reinterpret_cast<char*>(h),hNum*2);
                                        bin.close();
                                        hasH=true;withH++;hRes=side;
                                        if(isR(fhf+0x80,16)){minZ=*reinterpret_cast<double*>(fhf+0x80);maxZ=*reinterpret_cast<double*>(fhf+0x88);}
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if(!first)json<<",\n";first=false;
            json<<"{\"l\":"<<li<<",\"sx\":"<<sx<<",\"sy\":"<<sy
                <<",\"wx\":"<<(int64_t)wx<<",\"wy\":"<<(int64_t)wy
                <<",\"h\":"<<(hasH?1:0);
            if(hasH)json<<",\"minZ\":"<<minZ<<",\"maxZ\":"<<maxZ<<",\"res\":"<<hRes;
            json<<",\"f\":\"hf_l"<<li<<"_s"<<sx<<"_"<<sy<<".bin\"}";
            total++;
            return RC::LoopAction::Continue;});

        json<<"]}\n";
        auto result=hme::commitTerrain(outDir,json.str(),withH);
        Output::send<LogLevel::Verbose>(STR("[HME] Done: {}/{} with heights\n"),withH,total);
        if(result==hme::Commit::Empty)Output::send<LogLevel::Verbose>(STR("[HME] No height data (world not loaded?): terrain_v17.json left as it was\n"));
        if(result==hme::Commit::Failed)Output::send<LogLevel::Verbose>(STR("[HME] Could not write terrain_v17.json: left as it was\n"));
        hme::writeDone(outDir,result);
    }
};

extern "C" __declspec(dllexport) RC::CppUserModBase* start_mod(){return new HeightmapExporter();}
extern "C" __declspec(dllexport) void uninstall_mod(RC::CppUserModBase* mod){delete mod;}
