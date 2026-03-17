// hackshield_stub.c - stubs pour fonctions anti-cheat manquantes
// Compile avec /TP (C++) pour gerer les deux types de mangling :
//   - HackShield/APex : extern "C" + __stdcall -> decoration C (@N)
//   - XTrap           : __cdecl C++ -> mangling C++ (?...)

extern "C" {
// HackShield
int __stdcall _AhnHS_InitializeA(const char* a, void* b, int c, const char* d, unsigned int e, unsigned int f) { return 0; }
int __stdcall _AhnHS_StartService(void)  { return 0; }
int __stdcall _AhnHS_StopService(void)   { return 0; }
int __stdcall _AhnHS_Uninitialize(void)  { return 0; }
int __stdcall _AhnHS_MakeResponse(unsigned char* a, unsigned long b, void* c) { return 0; }
// HSUpdateExA : la fonction attend 804 octets de parametres (__stdcall = callee clean)
#pragma comment(linker, "/alternatename:__AhnHS_HSUpdateExA@804=__AhnHS_HSUpdateExA@0")
__declspec(naked) void __stdcall _AhnHS_HSUpdateExA(void)
{
    __asm
    {
        xor eax, eax
        ret 804
    }
}
// APex
long __stdcall CHCStart(void* a, void* b) { return 0; }
long __stdcall CHCEnd(void)               { return 0; }
} // extern "C"

// XTrap - appele depuis du code C++ sans extern "C" -> mangling C++
void __cdecl XTrap_C_Start(const char* a, const char* b) { (void)a; (void)b; }
void __cdecl XTrap_C_KeepAlive(void) {}
void __cdecl XTrap_C_SetUserInfo(const char* a, const char* b, const char* c, const char* d, unsigned long e) { (void)a; (void)b; (void)c; (void)d; (void)e; }