using System;
using System.Windows.Forms;
class Fixture {
 [STAThread] static void Main() {
#if BROKEN
  return;
#else
  Application.EnableVisualStyles();
  Application.Run(new Form {Text="Bakım.TR Yardım",Width=650,Height=340,StartPosition=FormStartPosition.CenterScreen,Controls={new Label {Text="Bakım.TR Yardım — izole güncelleme testi",AutoSize=true,Left=35,Top=45}}});
#endif
 }
}
