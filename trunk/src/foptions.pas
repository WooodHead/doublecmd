{
   Double Commander
   -------------------------------------------------------------------------
   Implementing of Options dialog

   Copyright (C) 2006-2011  Koblov Alexander (Alexx2000@mail.ru)

   contributors:

   Radek Cervinka  <radek.cervinka@centrum.cz>

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 2 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
}

unit fOptions;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Controls, Forms, Dialogs, ExtCtrls, ComCtrls, Buttons,
  fgl, uGlobs, fOptionsFrame;

type

  { TOptionsEditorView }

  TOptionsEditorView = class
    EditorType: TOptionsEditorType;
    EditorClass: TOptionsEditorClass;
    Instance: TOptionsEditor;
    TreeNode: TTreeNode;
  end;

  TOptionsEditorViews = specialize TFPGObjectList<TOptionsEditorView>;

  { TfrmOptions }

  TfrmOptions = class(TForm)
    Panel1: TPanel;
    Panel3: TPanel;
    pnlCaption: TPanel;
    btnOK: TBitBtn;
    btnApply: TBitBtn;
    btnCancel: TBitBtn;
    ilTreeView: TImageList;
    tvTreeView: TTreeView;
    splOptionsSplitter: TSplitter;
    procedure FormCreate(Sender: TObject);
    procedure btnOKClick(Sender: TObject);
    procedure btnApplyClick(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure tvTreeViewChange(Sender: TObject; Node: TTreeNode);
  private
    FOptionsEditorList: TOptionsEditorViews;
    FOldEditor: TOptionsEditorView;
    procedure CreateOptionsEditorList;
    procedure SelectEditor(EditorType: TOptionsEditorType);
  public
    constructor Create(TheOwner: TComponent); override;
    constructor Create(TheOwner: TComponent; EditorType: TOptionsEditorType); overload;
    procedure LoadConfig;
    procedure SaveConfig;
  end;

implementation

{$R *.lfm}

uses
  LCLProc, LCLVersion, uLng, fMain,
  fOptionsPlugins, fOptionsToolTips, fOptionsColors, fOptionsLanguage,
  fOptionsBehaviour, fOptionsTools, fOptionsHotkeys, fOptionsLayout,
  fOptionsFonts, fOptionsFileOperations, fOptionsQuickSearchFilter,
  fOptionsTabs, fOptionsLog, fOptionsConfiguration, fOptionsColumns,
  fOptionsMisc, fOptionsAutoRefresh, fOptionsIcons, fOptionsIgnoreList,
  fOptionsArchivers;

const
  TOptionsEditorsIcons: array[TOptionsEditorType] of Integer =
    (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19);

procedure TfrmOptions.FormCreate(Sender: TObject);
begin
  // Initialize property storage
  InitPropStorage(Self);
end;

procedure TfrmOptions.btnOKClick(Sender: TObject);
begin
  // save all configuration
  SaveConfig;
  // write to config file
  SaveGlobs;
end;

procedure TfrmOptions.btnApplyClick(Sender: TObject);
begin
  // save all configuration
  SaveConfig;
  // write to config file
  SaveGlobs;
end;

procedure TfrmOptions.FormDestroy(Sender: TObject);
begin
  FreeThenNil(FOptionsEditorList);
end;

procedure TfrmOptions.CreateOptionsEditorList;
var
  I: LongInt;
  aOptionsEditor: TOptionsEditor;
  aOptionsEditorClass: TOptionsEditorClass;
  aOptionsEditorView: TOptionsEditorView;
  TreeNode: TTreeNode;
  IconIndex: Integer;
begin
  FOptionsEditorList:= TOptionsEditorViews.Create;
  for I:= 0 to OptionsEditorClassList.Count - 1 do
  begin
    aOptionsEditorClass := OptionsEditorClassList[I].OptionsEditorClass;

    aOptionsEditorView := TOptionsEditorView.Create;
    aOptionsEditorView.EditorClass := aOptionsEditorClass;
    aOptionsEditorView.EditorType  := OptionsEditorClassList[I].OptionsEditorType;
    aOptionsEditorView.Instance    := nil;

    FOptionsEditorList.Add(aOptionsEditorView);

    TreeNode := tvTreeView.Items.Add(nil, aOptionsEditorClass.GetTitle);
    if Assigned(TreeNode) then
    begin
      IconIndex := TOptionsEditorsIcons[OptionsEditorClassList[I].OptionsEditorType];
      TreeNode.ImageIndex    := IconIndex;
      TreeNode.SelectedIndex := IconIndex;
      TreeNode.StateIndex    := IconIndex;
      TreeNode.Data          := aOptionsEditorView;
    end;

    aOptionsEditorView.TreeNode := TreeNode;
  end;
end;

procedure TfrmOptions.SelectEditor(EditorType: TOptionsEditorType);
var
  I: Integer;
begin
  for I := 0 to FOptionsEditorList.Count - 1 do
  begin
    if (FOptionsEditorList[I].EditorType = EditorType) then
      if Assigned(FOptionsEditorList[I].TreeNode) then
      begin
        FOptionsEditorList[I].TreeNode.Selected := True;
        Break;
      end;
  end;
end;

constructor TfrmOptions.Create(TheOwner: TComponent);
begin
  Create(TheOwner, Low(TOptionsEditorType)); // Select first editor.
end;

constructor TfrmOptions.Create(TheOwner: TComponent; EditorType: TOptionsEditorType);
begin
  FOldEditor := nil;
  inherited Create(TheOwner);
  CreateOptionsEditorList;
  SelectEditor(EditorType);
end;

procedure TfrmOptions.tvTreeViewChange(Sender: TObject; Node: TTreeNode);
var
  SelectedEditorView: TOptionsEditorView;
begin
  SelectedEditorView := TOptionsEditorView(Node.Data);

  if Assigned(SelectedEditorView) and (FOldEditor <> SelectedEditorView) then
  begin
    if Assigned(FOldEditor) and Assigned(FOldEditor.Instance) then
      FOldEditor.Instance.Visible := False;

    if not Assigned(SelectedEditorView.Instance) then
    begin
      SelectedEditorView.Instance := SelectedEditorView.EditorClass.Create(Self);
      SelectedEditorView.Instance.Align   := alClient;
      SelectedEditorView.Instance.Visible := True;
      SelectedEditorView.Instance.Parent  := Panel3;
      SelectedEditorView.Instance.Load;
    end;

    SelectedEditorView.Instance.Visible := True;

    FOldEditor := SelectedEditorView;

    pnlCaption.Caption := SelectedEditorView.EditorClass.GetTitle;
  end;
end;

procedure TfrmOptions.LoadConfig;
var
  I: LongInt;
begin
  { Load options to frames }
  for I:= 0 to FOptionsEditorList.Count - 1 do
  begin
    if Assigned(FOptionsEditorList[I].Instance) then
      FOptionsEditorList[I].Instance.Load;
  end;
end;

procedure TfrmOptions.SaveConfig;
var
  I: LongInt;
  NeedsRestart: Boolean = False;
begin
  { Save options from frames }
  for I:= 0 to FOptionsEditorList.Count - 1 do
    if Assigned(FOptionsEditorList[I].Instance) then
      if oesfNeedsRestart in FOptionsEditorList[I].Instance.Save then
        NeedsRestart := True;

  if NeedsRestart then
    MessageDlg(rsMsgRestartForApplyChanges, mtInformation, [mbOK], 0);

  frmMain.UpdateWindowView;
end;

end.
